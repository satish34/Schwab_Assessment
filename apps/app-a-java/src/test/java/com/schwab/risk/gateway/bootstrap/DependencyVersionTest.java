package com.schwab.risk.gateway.bootstrap;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.catalina.startup.Tomcat;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringBootVersion;

class DependencyVersionTest {

  @Test
  void usesTheReviewedSpringBootAndTomcatPatchVersions() {
    assertThat(SpringBootVersion.getVersion()).isEqualTo("3.5.16");
    assertThat(Tomcat.class.getPackage().getImplementationVersion()).isEqualTo("10.1.57");
    assertThat(ObjectMapper.class.getPackage().getImplementationVersion()).isEqualTo("2.21.5");
  }
}
