package com.schwab.exchange.gateway.auth;

import java.util.Optional;

@FunctionalInterface
public interface AppBIdentityTokenProvider {

  Optional<String> identityToken();

  default boolean authenticationRequired() {
    return true;
  }
}
