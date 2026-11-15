package mill.javalib.api;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks a test whose failure is reported but does not fail the test task.
 *
 * @param value the reason why the test is quarantined
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface Quarantined {
  String value();
}
