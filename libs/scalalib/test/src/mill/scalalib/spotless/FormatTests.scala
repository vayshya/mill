package mill.scalalib.spotless

import mill.javalib.spotless.Format
import utest.*

object FormatTests extends TestSuite {
  def tests = Tests {
    test("relPathRefRoundTrip") {
      val value = Format.RelPathRef("path.conf")
      val json = upickle.write(value)
      val decoded = upickle.read[Format.RelPathRef](json)
      assert(decoded == value)
    }
    test("eclipseJdtRoundTrip") {
      val step: Format.Step = Format.EclipseJdt(
        version = "4.35",
        settingsFiles = Seq(Format.RelPathRef("formatter.xml"))
      )
      val decoded = upickle.read[Format.Step](upickle.write(step))
      assert(decoded == step)
    }
  }
}
