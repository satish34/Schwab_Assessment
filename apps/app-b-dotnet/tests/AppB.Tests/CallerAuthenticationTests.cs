using Google.Apis.Auth;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;

namespace AppB.Tests;

public sealed class CallerAuthenticationTests
{
    private const long Now = 2_000_000_000;
    private const string ProjectId = "test-project";
    private const string CallerEmail =
        "currency-app-a-caller@test-project.iam.gserviceaccount.com";

    private static readonly AppBAuthenticationSettings Settings = new(
        AppBAuthenticationMode.GoogleIdToken,
        AppBAuthenticationSettings.DefaultAudience,
        CallerEmail);

    [Fact]
    public void ConfigurationDefaultsToFailClosedGoogleIdTokenMode()
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["GOOGLE_CLOUD_PROJECT"] = ProjectId,
                ["APP_A_IDENTITY_EMAIL"] = CallerEmail,
            })
            .Build();

        var settings = AppBAuthenticationSettings.FromConfiguration(
            configuration,
            new TestHostEnvironment(Environments.Production));

        Assert.Equal(AppBAuthenticationMode.GoogleIdToken, settings.Mode);
        Assert.Equal(AppBAuthenticationSettings.DefaultAudience, settings.Audience);
        Assert.Equal(CallerEmail, settings.ExpectedCallerEmail);
    }

    [Theory]
    [InlineData("Development")]
    [InlineData("Staging")]
    [InlineData("Production")]
    public void DisabledModeIsRejectedOutsideLocalComposeAndTests(string environmentName)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["APP_B_AUTH_MODE"] = AppBAuthenticationSettings.DisabledModeName,
            })
            .Build();

        var exception = Assert.Throws<InvalidOperationException>(() =>
            AppBAuthenticationSettings.FromConfiguration(
                configuration,
                new TestHostEnvironment(environmentName)));

        Assert.Contains("LocalCompose or Testing", exception.Message);
    }

    [Theory]
    [InlineData("")]
    [InlineData("currency-app-a-caller@PROJECT_ID.iam.gserviceaccount.com")]
    [InlineData("currency-app-a-caller@bad value.iam.gserviceaccount.com")]
    [InlineData("another-caller@test-project.iam.gserviceaccount.com")]
    [InlineData("currency-app-a-caller@another-project.iam.gserviceaccount.com")]
    public void GoogleModeRejectsCallerIdentityThatDoesNotExactlyMatchProject(string email)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["GOOGLE_CLOUD_PROJECT"] = ProjectId,
                ["APP_A_IDENTITY_EMAIL"] = email,
            })
            .Build();

        Assert.Throws<InvalidOperationException>(() =>
            AppBAuthenticationSettings.FromConfiguration(
                configuration,
                new TestHostEnvironment(Environments.Production)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("short")]
    [InlineData("PROJECT_ID")]
    [InlineData("test_project")]
    [InlineData("-test-project")]
    [InlineData("test-project-")]
    public void GoogleModeRequiresAValidGoogleCloudProject(string? projectId)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["GOOGLE_CLOUD_PROJECT"] = projectId,
                ["APP_A_IDENTITY_EMAIL"] = CallerEmail,
            })
            .Build();

        var exception = Assert.Throws<InvalidOperationException>(() =>
            AppBAuthenticationSettings.FromConfiguration(
                configuration,
                new TestHostEnvironment(Environments.Production)));

        Assert.Contains("GOOGLE_CLOUD_PROJECT", exception.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(AppBAuthenticationSettings.LocalComposeEnvironmentName)]
    [InlineData("Testing")]
    public void DisabledModeIsExplicitlyAvailableForLocalComposeAndTests(string environmentName)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["APP_B_AUTH_MODE"] = AppBAuthenticationSettings.DisabledModeName,
            })
            .Build();

        var settings = AppBAuthenticationSettings.FromConfiguration(
            configuration,
            new TestHostEnvironment(environmentName));

        Assert.Equal(AppBAuthenticationMode.Disabled, settings.Mode);
    }

    [Theory]
    [MemberData(nameof(RejectedClaims))]
    public void ClaimPolicyRejectsInvalidOrMissingClaims(
        GoogleIdTokenClaims claims,
        string expectedErrorType)
    {
        var policy = new AppACallerClaimPolicy(
            Settings,
            new FixedTimeProvider(DateTimeOffset.FromUnixTimeSeconds(Now)));

        var result = policy.Validate(claims);

        Assert.False(result.Succeeded);
        Assert.Equal(expectedErrorType, result.ErrorType);
    }

    [Theory]
    [InlineData("accounts.google.com")]
    [InlineData("https://accounts.google.com")]
    public void ClaimPolicyAcceptsExactVerifiedCaller(string issuer)
    {
        var policy = new AppACallerClaimPolicy(
            Settings,
            new FixedTimeProvider(DateTimeOffset.FromUnixTimeSeconds(Now)));

        var result = policy.Validate(ValidClaims() with { Issuer = issuer });

        Assert.True(result.Succeeded);
        Assert.Equal(string.Empty, result.ErrorType);
    }

    [Fact]
    public async Task MissingAuthorizationDoesNotInvokeSignatureVerifier()
    {
        var verifier = new StubVerifier(
            GoogleIdTokenVerificationResult.Valid(ValidClaims()));
        var authenticator = CreateAuthenticator(verifier);
        var context = new DefaultHttpContext();

        var result = await authenticator.AuthenticateAsync(
            context.Request,
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal("authorization_missing", result.ErrorType);
        Assert.Equal(0, verifier.CallCount);
    }

    [Fact]
    public async Task DuplicateAuthorizationDoesNotInvokeSignatureVerifier()
    {
        var verifier = new StubVerifier(
            GoogleIdTokenVerificationResult.Valid(ValidClaims()));
        var authenticator = CreateAuthenticator(verifier);
        var context = new DefaultHttpContext();
        context.Request.Headers.Append("Authorization", "Bearer first.token.value");
        context.Request.Headers.Append("Authorization", "Bearer second.token.value");

        var result = await authenticator.AuthenticateAsync(
            context.Request,
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal("authorization_duplicate", result.ErrorType);
        Assert.Equal(0, verifier.CallCount);
    }

    [Theory]
    [InlineData("")]
    [InlineData("Basic header.payload.signature")]
    [InlineData("Bearer")]
    [InlineData("Bearer  header.payload.signature")]
    [InlineData("Bearer header.payload.signature extra")]
    [InlineData("Bearer first.token.value, Bearer second.token.value")]
    public async Task MalformedAuthorizationDoesNotInvokeSignatureVerifier(string header)
    {
        var verifier = new StubVerifier(
            GoogleIdTokenVerificationResult.Valid(ValidClaims()));
        var authenticator = CreateAuthenticator(verifier);
        var context = new DefaultHttpContext();
        context.Request.Headers.Authorization = header;

        var result = await authenticator.AuthenticateAsync(
            context.Request,
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal("authorization_malformed", result.ErrorType);
        Assert.Equal(0, verifier.CallCount);
    }

    [Fact]
    public async Task BearerTokenIsVerifiedExactlyOnceAgainstTheFrozenAudience()
    {
        var verifier = new StubVerifier(
            GoogleIdTokenVerificationResult.Valid(ValidClaims()));
        var authenticator = CreateAuthenticator(verifier);
        var context = new DefaultHttpContext();
        context.Request.Headers.Authorization = "Bearer header.payload.signature";

        var result = await authenticator.AuthenticateAsync(
            context.Request,
            CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Equal(1, verifier.CallCount);
        Assert.Equal("header.payload.signature", verifier.LastToken);
        Assert.Equal(AppBAuthenticationSettings.DefaultAudience, verifier.LastAudience);
    }

    [Fact]
    public async Task SignatureFailureFailsClosed()
    {
        var verifier = new StubVerifier(GoogleIdTokenVerificationResult.InvalidToken);
        var authenticator = CreateAuthenticator(verifier);
        var context = new DefaultHttpContext();
        context.Request.Headers.Authorization = "Bearer invalid.token.signature";

        var result = await authenticator.AuthenticateAsync(
            context.Request,
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal("token_validation_failed", result.ErrorType);
        Assert.Equal(1, verifier.CallCount);
    }

    [Fact]
    public async Task VerifierUnavailabilityFailsClosedWithADistinctInternalReason()
    {
        var verifier = new StubVerifier(GoogleIdTokenVerificationResult.VerifierUnavailable);
        var authenticator = CreateAuthenticator(verifier);
        var context = new DefaultHttpContext();
        context.Request.Headers.Authorization = "Bearer header.payload.signature";

        var result = await authenticator.AuthenticateAsync(
            context.Request,
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal("token_verifier_unavailable", result.ErrorType);
        Assert.Equal(1, verifier.CallCount);
    }

    [Theory]
    [InlineData("not-a-jwt")]
    [InlineData("e30.!.signature")]
    public async Task OfficialGoogleVerifierClassifiesMalformedJwtWithoutANetworkDependency(
        string token)
    {
        var verifier = new GoogleIdTokenVerifier(new GoogleJsonWebSignatureValidator());

        var result = await verifier.VerifyAsync(
            token,
            AppBAuthenticationSettings.DefaultAudience,
            CancellationToken.None);

        Assert.Equal(GoogleIdTokenVerificationStatus.InvalidToken, result.Status);
        Assert.False(result.Succeeded);
    }

    [Fact]
    public async Task GoogleVerifierMapsTheOfficialPayloadAndFrozenAudience()
    {
        var signatureValidator = new StubSignatureValidator(() => new GoogleJsonWebSignature.Payload
        {
            Issuer = "https://accounts.google.com",
            Audience = AppBAuthenticationSettings.DefaultAudience,
            IssuedAtTimeSeconds = Now - 60,
            ExpirationTimeSeconds = Now + 3600,
            NotBeforeTimeSeconds = Now - 60,
            Email = CallerEmail,
            EmailVerified = true,
        });
        var verifier = new GoogleIdTokenVerifier(signatureValidator);

        var result = await verifier.VerifyAsync(
            "header.payload.signature",
            AppBAuthenticationSettings.DefaultAudience,
            CancellationToken.None);

        Assert.Equal(GoogleIdTokenVerificationStatus.Valid, result.Status);
        Assert.True(result.Succeeded);
        Assert.NotNull(result.Claims);
        Assert.Equal(CallerEmail, result.Claims.Email);
        Assert.Equal([AppBAuthenticationSettings.DefaultAudience], result.Claims.Audiences);
        Assert.Equal(1, signatureValidator.CallCount);
        Assert.Equal("header.payload.signature", signatureValidator.LastToken);
        Assert.Equal(AppBAuthenticationSettings.DefaultAudience, signatureValidator.LastAudience);
    }

    [Fact]
    public async Task GoogleVerifierDistinguishesInvalidTokenFromVerifierFailure()
    {
        var invalidVerifier = new GoogleIdTokenVerifier(new StubSignatureValidator(
            () => throw new InvalidJwtException("attacker-controlled token details")));
        var unavailableVerifier = new GoogleIdTokenVerifier(new StubSignatureValidator(
            () => throw new HttpRequestException("Google certificate endpoint unavailable")));

        var invalid = await invalidVerifier.VerifyAsync(
            "invalid.token.signature",
            AppBAuthenticationSettings.DefaultAudience,
            CancellationToken.None);
        var unavailable = await unavailableVerifier.VerifyAsync(
            "valid-looking.token.signature",
            AppBAuthenticationSettings.DefaultAudience,
            CancellationToken.None);

        Assert.Equal(GoogleIdTokenVerificationStatus.InvalidToken, invalid.Status);
        Assert.Equal(GoogleIdTokenVerificationStatus.VerifierUnavailable, unavailable.Status);
        Assert.False(invalid.Succeeded);
        Assert.False(unavailable.Succeeded);
    }

    public static IEnumerable<object[]> RejectedClaims()
    {
        yield return [ValidClaims() with { Issuer = null }, "token_issuer_invalid"];
        yield return [ValidClaims() with { Issuer = "https://issuer.example" }, "token_issuer_invalid"];
        yield return [ValidClaims() with { Audiences = [] }, "token_audience_invalid"];
        yield return [ValidClaims() with { Audiences = ["wrong-audience"] }, "token_audience_invalid"];
        yield return
        [
            ValidClaims() with
            {
                Audiences = [AppBAuthenticationSettings.DefaultAudience, "another-audience"],
            },
            "token_audience_invalid",
        ];
        yield return [ValidClaims() with { IssuedAtUnixSeconds = null }, "token_lifetime_invalid"];
        yield return [ValidClaims() with { ExpirationUnixSeconds = null }, "token_lifetime_invalid"];
        yield return
        [
            ValidClaims() with { IssuedAtUnixSeconds = Now + 31 },
            "token_lifetime_invalid",
        ];
        yield return
        [
            ValidClaims() with { ExpirationUnixSeconds = Now },
            "token_lifetime_invalid",
        ];
        yield return
        [
            ValidClaims() with
            {
                IssuedAtUnixSeconds = Now - 10,
                ExpirationUnixSeconds = Now - 11,
            },
            "token_lifetime_invalid",
        ];
        yield return
        [
            ValidClaims() with { NotBeforeUnixSeconds = Now + 31 },
            "token_lifetime_invalid",
        ];
        yield return [ValidClaims() with { Email = null }, "caller_email_missing"];
        yield return [ValidClaims() with { Email = "" }, "caller_email_missing"];
        yield return [ValidClaims() with { EmailVerified = false }, "caller_email_unverified"];
        yield return
        [
            ValidClaims() with { Email = "another-caller@test-project.iam.gserviceaccount.com" },
            "caller_identity_invalid",
        ];
    }

    private static AppBRequestAuthenticator CreateAuthenticator(StubVerifier verifier)
    {
        var policy = new AppACallerClaimPolicy(
            Settings,
            new FixedTimeProvider(DateTimeOffset.FromUnixTimeSeconds(Now)));
        return new AppBRequestAuthenticator(Settings, verifier, policy);
    }

    private static GoogleIdTokenClaims ValidClaims() => new(
        "https://accounts.google.com",
        [AppBAuthenticationSettings.DefaultAudience],
        Now - 60,
        Now + 3600,
        Now - 60,
        CallerEmail,
        true);

    private sealed class StubVerifier(
        GoogleIdTokenVerificationResult result) : IGoogleIdTokenVerifier
    {
        public int CallCount { get; private set; }

        public string? LastToken { get; private set; }

        public string? LastAudience { get; private set; }

        public Task<GoogleIdTokenVerificationResult> VerifyAsync(
            string token,
            string audience,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            LastToken = token;
            LastAudience = audience;
            return Task.FromResult(result);
        }
    }

    private sealed class StubSignatureValidator(
        Func<GoogleJsonWebSignature.Payload> validate) : IGoogleJsonWebSignatureValidator
    {
        public int CallCount { get; private set; }

        public string? LastToken { get; private set; }

        public string? LastAudience { get; private set; }

        public Task<GoogleJsonWebSignature.Payload> ValidateAsync(
            string token,
            string audience,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CallCount++;
            LastToken = token;
            LastAudience = audience;
            return Task.FromResult(validate());
        }
    }

    private sealed class FixedTimeProvider(DateTimeOffset utcNow) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => utcNow;
    }

    private sealed class TestHostEnvironment(string environmentName) : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "AppB.Tests";

        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();

        public string WebRootPath { get; set; } = string.Empty;

        public string EnvironmentName { get; set; } = environmentName;

        public string ContentRootPath { get; set; } = string.Empty;

        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
