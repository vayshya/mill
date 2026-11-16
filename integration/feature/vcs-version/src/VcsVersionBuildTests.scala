package mill.integration

import mill.testkit.UtestIntegrationTestSuite
import os.Path
import utest.*

object VcsVersionBuildTests extends UtestIntegrationTestSuite {

  override protected def workspaceSourcePath: Path =
    os.Path(os.proc("git", "rev-parse", "--show-toplevel").call().out.trim())

  private def git(cwd: Path, args: String*): String =
    os.proc(Seq("git") ++ args).call(cwd = cwd, stderr = os.Pipe).out.trim()

  val tests: Tests = Tests {
    test("VCSV-CHAR-07 build version fallback without tags") - integrationTest { tester =>
      import tester.*

      val tags = git(workspacePath, "tag", "--list").linesIterator.filter(_.nonEmpty).toSeq
      tags.foreach(tag => git(workspacePath, "tag", "-d", tag))
      assert(git(workspacePath, "tag", "--list").isEmpty)

      val version = eval(("millVersion"))
      val lastTag = eval(("millLastTag"))

      assert(version.isSuccess)
      assert(version.out.contains("SNAPSHOT"))
      assert(lastTag.isSuccess)
      assert(lastTag.out.contains("SNAPSHOT"))
    }

    test("VCSV-CHAR-08 build version ignores dirty state in CI") - integrationTest { tester =>
      import tester.*

      val tag = "vcs-version-characterization"
      git(workspacePath, "tag", tag, "HEAD")
      os.write.append(workspacePath / "README.md", "\nVCS version characterization dirty change\n")
      assert(git(workspacePath, "diff", "HEAD").nonEmpty)

      val outsideCi = eval(
        ("millVersion"),
        env = sys.env - "CI",
        propagateEnv = false
      )
      val inCi = eval(("millVersion"), env = Map("CI" -> "true"))

      assert(outsideCi.isSuccess)
      assert(outsideCi.out.contains(tag))
      assert(outsideCi.out.contains("DIRTY"))
      assert(inCi.isSuccess)
      assert(inCi.out.contains(tag))
      assert(!inCi.out.contains("DIRTY"))
    }
  }
}
