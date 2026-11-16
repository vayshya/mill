package mill.launcher

import coursier.{Artifacts, Dependency, ModuleName, Organization, Resolve, VersionConstraint}
import coursier.cache.{ArchiveCache, FileCache}
import coursier.jvm.{JavaHome, JvmCache, JvmIndex}
import coursier.util.Task
import coursier.core.Module
import mill.constants.BuildInfo
import upickle.default.*

import scala.concurrent.ExecutionContext.Implicits.global
import java.net.URI
import java.nio.file.{AtomicMoveNotSupportedException, FileAlreadyExistsException, StandardCopyOption}
import java.security.MessageDigest
import java.nio.file.Paths
import mill.api.JsonFormatters.*

object CoursierClient {

  private def cacheDir(outDir: String): os.Path =
    os.Path(outDir, os.pwd) / "mill-daemon" / "cache"

  /**
   * Single-entry disk cache for expensive Coursier resolutions, as even when everything
   * is already downloaded Coursier's cache checking can take >100ms
   *
   * Stores a JSON tuple of (cacheKey, data) in the cache file.
   */
  private def cached[T: ReadWriter](
      cacheFile: os.Path,
      cacheKey: String,
      // Make sure we validate the correctness of cache entries because they may have
      // been deleted or moved in between the cache being populated and us using it
      validate: T => Boolean
  )(compute: => T): T = {
    // Try to read from cache
    val cachedValue: Option[T] =
      if (os.exists(cacheFile)) {
        try {
          val content = os.read(cacheFile)
          val (storedKey, value) = read[(String, T)](content)
          if (storedKey == cacheKey && validate(value)) Some(value) else None
        } catch {
          case _: Exception => None
        }
      } else None

    cachedValue match {
      case Some(value) => value
      case None =>
        val value = compute
        os.write.over(cacheFile, write((cacheKey, value)), createFolders = true)
        value
    }
  }

  private def sha256(path: os.Path): String = {
    val digest = MessageDigest.getInstance("SHA-256")
    val input = os.read.inputStream(path)
    try {
      val buffer = new Array[Byte](8192)
      var read = input.read(buffer)
      while (read >= 0) {
        if (read > 0) digest.update(buffer, 0, read)
        read = input.read(buffer)
      }
    } finally input.close()
    digest.digest().map(b => f"${b & 0xff}%02x").mkString
  }

  private def fileRepositoryPath(repository: String): Option[os.Path] =
    if (repository.startsWith("file:")) {
      try Some(os.Path(Paths.get(new URI(repository))))
      catch { case _: Exception => None }
    } else None

  /**
   * The daemon outlives the launcher process. Coursier can still return the source path
   * for local SNAPSHOT artifacts, even when localArtifactsShouldBeCached is enabled.
   * Copy those artifacts into immutable, content-addressed files outside the repository
   * before using them as the daemon's JVM classpath.
   */
  private def stabilizeLocalArtifacts(
      classpath: Seq[os.Path],
      localRepositories: Seq[os.Path],
      outDir: String
  ): Seq[os.Path] = {
    val stableRoot = cacheDir(outDir) / "mill-daemon-local-artifacts"
    classpath.map { source =>
      if (!localRepositories.exists(source.startsWith)) source
      else {
        val digest = sha256(source)
        val destination = stableRoot / digest / source.last
        if (!os.exists(destination)) {
          os.makeDir.all(destination / os.up)
          val temporary = destination / os.up / s".${destination.last}.${java.util.UUID.randomUUID()}.tmp"
          os.copy.over(source, temporary)
          try {
            java.nio.file.Files.move(
              temporary.toNIO,
              destination.toNIO,
              StandardCopyOption.ATOMIC_MOVE
            )
          } catch {
            case _: FileAlreadyExistsException => os.remove(temporary)
            case _: AtomicMoveNotSupportedException =>
              try java.nio.file.Files.move(temporary.toNIO, destination.toNIO)
              catch { case _: FileAlreadyExistsException => os.remove(temporary) }
          }
        }
        destination
      }
    }
  }

  def resolveMillDaemon(outDir: String, millRepositories: Seq[String]): Seq[os.Path] = {
    // FIXME All the messing with COURSIER_REPOSITORIES assumes user override repos only via this env var,
    // rather than via Java properties or config files, whose use is less likely. Things might go wrong
    // if ever users rely on those.
    val overridesRepos = Option(System.getenv("COURSIER_REPOSITORIES"))
      .toSeq
      .flatMap(_.split('|').toSeq)

    val millRepositories0 = millRepositories.sorted

    val cacheKey =
      s"${BuildInfo.millVersion} local-artifacts-cached-v1 ${overridesRepos.reverse.mkString("|")}|${millRepositories0.mkString("|")}"

    val hasLocalRepositories = (overridesRepos ++ millRepositories0).exists { repo =>
      repo.startsWith("file:") || repo == "ivy2Local"
    }

    def resolveClasspath(): Seq[os.Path] = {
      val coursierCache0 = FileCache.create[Task]().copy(
        logger = coursier.cache.loggers.RefreshLogger.create(),
        // The daemon outlives this launcher invocation. Never leave its runner
        // classpath pointing into a temporary file repository such as dist.raw.localRepo.
        localArtifactsShouldBeCached = true
      )

      val configuredRepos = mill.util.Jvm.reposFromStrings(millRepositories0).get

      val artifactsResultOrError = {
        // configuredRepos (from mill-repositories) comes first so user config takes precedence
        val allRepos = configuredRepos ++ Resolve.defaultRepositories
        val resolve = Resolve().copy(
          cache = coursierCache0,
          dependencies = Seq(Dependency(
            Module(Organization("com.lihaoyi"), ModuleName("mill-runner-daemon_3"), Map()),
            VersionConstraint(BuildInfo.millVersion)
          )),
          repositories = allRepos
        )

        val result = resolve.either().flatMap { v =>
          Artifacts(coursierCache0)
            .withResolution(v)
            .eitherResult()
        }
        result match {
          case Left(e) => sys.error(e.toString())
          case Right(v) => v
        }
      }

      val resolvedArtifacts = artifactsResultOrError.artifacts.map(_._2.toString).toSeq.map(os.Path(_))
      val localRepositories = (overridesRepos ++ millRepositories0).flatMap(fileRepositoryPath).distinct
      stabilizeLocalArtifacts(resolvedArtifacts, localRepositories, outDir)
    }

    if (hasLocalRepositories) {
      // A cached classpath would keep serving old SNAPSHOT copies after the local
      // repository is republished. Let Coursier revalidate local files on each launch.
      resolveClasspath()
    } else {
      cached[Seq[os.Path]](
        cacheFile = cacheDir(outDir) / "mill-daemon-classpath",
        cacheKey = cacheKey,
        validate = paths => paths.forall(os.exists(_))
      )(resolveClasspath())
    }
  }

  def resolveJavaHome(
      id: String,
      jvmIndexVersionOpt: Option[String],
      outDir: String,
      millRepositories: Seq[String]
  ): os.Path = {
    val indexVersion = jvmIndexVersionOpt.getOrElse(mill.client.Versions.coursierJvmIndexVersion)
    val cacheKey = s"$id:$indexVersion:${millRepositories.sorted.mkString(":")}"

    cached[os.Path](
      cacheFile = cacheDir(outDir) / "java-home",
      cacheKey = cacheKey,
      validate = os.isDir(_)
    ) {
      val coursierCache0 = FileCache.create[Task]().copy(
        logger = coursier.cache.loggers.RefreshLogger.create()
      )

      val configuredRepos = mill.util.Jvm.reposFromStrings(millRepositories).get
      val jvmCache = JvmCache().copy(
        archiveCache = ArchiveCache().copy(cache = coursierCache0),
        index = Some(JvmIndex.load(
          cache = coursierCache0,
          repositories = configuredRepos ++ Resolve.defaultRepositories,
          indexChannel = mill.util.Jvm.jvmIndexChannel(indexVersion)
        ))
      )

      val javaHome = JavaHome().copy(
        cache = Some(jvmCache),
        // when given a version like "17", always pick highest version in the index
        // rather than the highest already on disk
        update = true
      )

      os.Path(coursierCache0.logger.using(javaHome.get(id)).unsafeRun()(using coursierCache0.ec))
    }

  }
}
