package mill.util

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

  private def state(repo: os.Path): VcsVersion.State =
    VcsVersion.calcVcsState(Logger.DummyLogger, repo)

  val tests: Tests = Tests {
    test("CV-01 exact tag at HEAD") {
      val repo = initRepo()
      commit(repo, "A")
      git(repo, "tag", "1.2.3")

      val result = state(repo)
      assert(result.lastTag == Some("1.2.3"))
      assert(result.commitsSinceLastTag == 0)
    }

    test("CV-02 HEAD after a reachable tag") {
      val repo = initRepo()
      commit(repo, "A")
      git(repo, "tag", "1.2.3")
      commit(repo, "B")
      commit(repo, "C")

      val result = state(repo)
      assert(result.lastTag == Some("1.2.3"))
      assert(result.commitsSinceLastTag == 2)
    }

    test("CV-03 no reachable tags") {
      val repo = initRepo()
      commit(repo, "A")
      commit(repo, "B")
      commit(repo, "C")

      val result = state(repo)
      assert(result.lastTag.isEmpty)
      assert(result.commitsSinceLastTag == 3)
    }

    test("CV-04 tag selection follows git describe") {
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

    test("CV-05 dirty working tree") {
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

    test("CV-06 directory without a Git repository") {
      val directory = os.temp.dir()
      val result = state(directory)

      assert(result.currentRevision == "no-vcs")
      assert(result.lastTag.isEmpty)
      assert(result.commitsSinceLastTag == 0)
      assert(result.dirtyHash.isEmpty)
      assert(result.vcs.isEmpty)
    }

    test("CV-09 upstream commits after the release tag are included") {
      val repo = initRepo()
      commit(repo, "A")
      commit(repo, "B")
      commit(repo, "C")
      git(repo, "tag", "1.4.0-M2")
      commit(repo, "upstream-D")
      commit(repo, "upstream-E")
      commit(repo, "fork-F")
      commit(repo, "fork-G")

      val result = state(repo)
      assert(result.lastTag == Some("1.4.0-M2"))
      assert(result.commitsSinceLastTag == 4)
    }

    test("CV-10 fork checkout without available tags") {
      val parent = os.temp.dir()
      val source = parent / "source"
      os.makeDir(source)
      git(source, "init", "--quiet")
      git(source, "config", "user.name", "VCS Version Tests")
      git(source, "config", "user.email", "vcs-version-tests@example.invalid")
      commit(source, "A")
      commit(source, "B")
      commit(source, "C")
      git(source, "tag", "1.4.0-M2")
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
      assert(VcsVersion.formatMillVersion(result, isCi = false) == "SNAPSHOT")
    }

    test("CV-11 divergent histories") {
      val repo = initRepo()
      val common = commit(repo, "common")
      git(repo, "tag", "base-release")
      git(repo, "branch", "upstream")
      git(repo, "checkout", "--quiet", "upstream")
      commit(repo, "upstream-1")
      commit(repo, "upstream-2")
      git(repo, "tag", "upstream-release")
      git(repo, "checkout", "--quiet", "-b", "fork", common)
      commit(repo, "fork-1")
      commit(repo, "fork-2")

      val result = state(repo)
      assert(result.lastTag == Some("base-release"))
      assert(result.commitsSinceLastTag == 2)
    }
  }
}
