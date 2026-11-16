package mill.util

import java.lang.reflect.{InvocationHandler, Proxy}

import mill.api.Logger
import utest.*

object VcsVersionGitTests extends TestSuite {

  private def git(cwd: os.Path, args: String*): String =
    os.proc(Seq("git") ++ args).call(cwd = cwd, stderr = os.Pipe).out.trim()

  private def initRepo(): os.Path = {
    val repo = os.temp.dir()
    git(repo, "init", "--quiet")
    git(repo, "config", "user.name", "VCS Version Tests")
    git(repo, "config", "user.email", "vcs-version-tests@example.invalid")
    repo
  }

  private def commit(repo: os.Path, name: String): String = {
    os.write(repo / s"$name.txt", name)
    git(repo, "add", s"$name.txt")
    git(repo, "commit", "--quiet", "-m", name)
    git(repo, "rev-parse", "HEAD")
  }

  private def state(repo: os.Path): VcsVersion.State = {
    // VcsVersion extends Module, so it cannot be instantiated directly in a test source.
    // A proxy supplies the test repository path and delegates the trait's default methods.
    val handler = new InvocationHandler {
      override def invoke(
          proxy: Any,
          method: java.lang.reflect.Method,
          args: Array[AnyRef]
      ): AnyRef = {
        if (method.getName == "vcsBasePath") repo
        else if (method.isDefault) {
          InvocationHandler.invokeDefault(proxy, method, Option(args).getOrElse(Array.empty): _*)
        } else {
          throw new UnsupportedOperationException(s"Unexpected VcsVersion method: ${method.getName}")
        }
      }
    }

    val version = Proxy
      .newProxyInstance(
        classOf[VcsVersion].getClassLoader,
        Array(classOf[VcsVersion]),
        handler
      )
      .asInstanceOf[VcsVersion]

    version.calcVcsState(Logger.DummyLogger)
  }

  val tests: Tests = Tests {
    test("VER-CV-01 exact tag at HEAD") {
      val repo = initRepo()
      commit(repo, "A")
      git(repo, "tag", "1.2.3")

      val result = state(repo)
      assert(result.lastTag == Some("1.2.3"))
      assert(result.commitsSinceLastTag == 0)
    }

    test("VER-CV-02 HEAD after a reachable tag") {
      val repo = initRepo()
      commit(repo, "A")
      git(repo, "tag", "1.2.3")
      commit(repo, "B")
      commit(repo, "C")

      val result = state(repo)
      assert(result.lastTag == Some("1.2.3"))
      assert(result.commitsSinceLastTag == 2)
    }

    test("VER-CV-03 no reachable tags") {
      val repo = initRepo()
      commit(repo, "A")
      commit(repo, "B")
      commit(repo, "C")

      val result = state(repo)
      assert(result.lastTag.isEmpty)
      assert(result.commitsSinceLastTag == 3)
    }

    test("VER-CV-04 tag selection follows git describe") {
      val repo = initRepo()
      commit(repo, "A")
      git(repo, "tag", "older-release")
      commit(repo, "B")
      commit(repo, "C")
      git(repo, "tag", "newer-release")
      commit(repo, "D")

      val describedTag = git(repo, "describe", "--abbrev=0", "--tags")
      val result = state(repo)
      assert(describedTag == "newer-release")
      assert(result.lastTag == Some(describedTag))
      assert(result.commitsSinceLastTag == 1)
    }

    test("VER-CV-05 dirty working tree") {
      val repo = initRepo()
      commit(repo, "A")
      os.write.over(repo / "A.txt", "modified")

      val diff = git(repo, "diff", "HEAD")
      val dirtyState = state(repo)
      assert(diff.nonEmpty)
      assert(dirtyState.dirtyHash == Some(Integer.toHexString(diff.hashCode)))

      git(repo, "add", "A.txt")
      git(repo, "commit", "--quiet", "-m", "modified")
      assert(state(repo).dirtyHash.isEmpty)
    }

    test("VER-CV-06 directory without a Git repository") {
      val directory = os.temp.dir()
      val result = state(directory)

      assert(result.currentRevision == "no-vcs")
      assert(result.lastTag.isEmpty)
      assert(result.commitsSinceLastTag == 0)
      assert(result.dirtyHash.isEmpty)
      assert(result.vcs.isEmpty)
    }

    test("VER-CV-09 upstream commits after the release tag are included") {
      val repo = initRepo()
      commit(repo, "A")
      commit(repo, "B")
      commit(repo, "C")
      git(repo, "tag", "1.4.0-M2")
      commit(repo, "upstream-D")
      val upstreamHead = commit(repo, "upstream-E")
      git(repo, "branch", "upstream", upstreamHead)
      git(repo, "checkout", "--quiet", "-b", "fork", upstreamHead)
      commit(repo, "fork-F")
      commit(repo, "fork-G")

      val result = state(repo)
      assert(result.lastTag == Some("1.4.0-M2"))
      assert(result.commitsSinceLastTag == 4)
    }

    test("VER-CV-12 rebase includes upstream commits in the count") {
      val repo = initRepo()
      commit(repo, "A")
      commit(repo, "B")
      commit(repo, "C")
      git(repo, "tag", "1.4.0-M2")
      git(repo, "branch", "upstream")
      git(repo, "checkout", "--quiet", "-b", "fork")
      commit(repo, "fork-F")
      commit(repo, "fork-G")

      git(repo, "checkout", "--quiet", "upstream")
      commit(repo, "upstream-D")
      val upstreamHead = commit(repo, "upstream-E")
      git(repo, "checkout", "--quiet", "fork")
      git(repo, "rebase", "upstream")

      assert(git(repo, "merge-base", "fork", "upstream") == upstreamHead)
      val result = state(repo)
      assert(result.lastTag == Some("1.4.0-M2"))
      // The main implementation counts both upstream-D/upstream-E and rebased fork-F/fork-G.
      assert(result.commitsSinceLastTag == 4)
    }

    test("VER-CV-10 fork checkout without available tags") {
      val parent = os.temp.dir()
      val source = parent / "source"
      os.makeDir(source)
      git(source, "init", "--quiet")
      git(source, "config", "user.name", "VCS Version Tests")
      git(source, "config", "user.email", "vcs-version-tests@example.invalid")
      commit(source, "A")
      commit(source, "B")
      commit(source, "C")
      commit(source, "D")
      commit(source, "E")
      commit(source, "F")
      commit(source, "G")

      val checkout = parent / "checkout"
      os.proc("git", "clone", "--quiet", "--no-tags", source.toString, checkout.toString)
        .call(cwd = parent, stderr = os.Pipe)

      val result = state(checkout)
      assert(git(checkout, "tag", "--list").isEmpty)
      assert(result.lastTag.isEmpty)
      assert(result.commitsSinceLastTag == 7)
    }

    test("VER-CV-13 upstream tag is unavailable when not fetched locally") {
      val parent = os.temp.dir()
      val upstream = initRepo()
      commit(upstream, "A")
      commit(upstream, "B")
      commit(upstream, "C")
      git(upstream, "tag", "1.4.0-M2")
      commit(upstream, "upstream-D")
      commit(upstream, "upstream-E")

      val bareUpstream = parent / "upstream.git"
      os.proc("git", "clone", "--quiet", "--bare", upstream.toString, bareUpstream.toString)
        .call(cwd = parent, stderr = os.Pipe)

      val checkout = parent / "fork"
      os.proc("git", "clone", "--quiet", "--no-tags", bareUpstream.toString, checkout.toString)
        .call(cwd = parent, stderr = os.Pipe)
      git(checkout, "remote", "rename", "origin", "upstream")
      commit(checkout, "fork-F")
      commit(checkout, "fork-G")

      assert(git(checkout, "tag", "--list").isEmpty)
      assert(git(checkout, "ls-remote", "--tags", "upstream", "refs/tags/1.4.0-M2").nonEmpty)

      val result = state(checkout)
      assert(result.lastTag.isEmpty)
      assert(result.commitsSinceLastTag == 7)
    }

  }
}
