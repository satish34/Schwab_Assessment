package com.schwab.exchange.gateway.auth;

public final class IdentityTokenUnavailableException extends RuntimeException {

  public IdentityTokenUnavailableException() {
    super("Google identity token is unavailable");
  }
}
