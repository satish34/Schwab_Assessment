package com.schwab.exchange.gateway.auth;

import java.util.Optional;

public enum DisabledAppBIdentityTokenProvider implements AppBIdentityTokenProvider {
  INSTANCE;

  @Override
  public Optional<String> identityToken() {
    return Optional.empty();
  }

  @Override
  public boolean authenticationRequired() {
    return false;
  }
}
