using Google.Apis.Auth;

namespace AppB;

public enum AppBAuthenticationMode
{
    GoogleIdToken,
    Disabled,
}

public sealed record AppBAuthenticationSettings(
    AppBAuthenticationMode Mode,
    string Audience,
    string ExpectedCallerEmail)
{
    public const string DefaultAudience = "https://app-b-engine.schwab-assessment.internal";
    public const string GoogleIdTokenModeName = "google-id-token";
    public const string DisabledModeName = "disabled";
    public const string LocalComposeEnvironmentName = "LocalCompose";
    private const string CallerEmailPrefix = "currency-app-a-caller@";
    private const string CallerEmailSuffix = ".iam.gserviceaccount.com";

    public static AppBAuthenticationSettings FromConfiguration(
        IConfiguration configuration,
        IHostEnvironment environment)
    {
        var configuredMode = configuration["APP_B_AUTH_MODE"]?.Trim();
        var mode = configuredMode switch
        {
            null or "" or GoogleIdTokenModeName => AppBAuthenticationMode.GoogleIdToken,
            DisabledModeName => AppBAuthenticationMode.Disabled,
            _ => throw new InvalidOperationException(
                "APP_B_AUTH_MODE must be google-id-token or disabled."),
        };

        if (mode == AppBAuthenticationMode.Disabled)
        {
            if (!environment.IsEnvironment(LocalComposeEnvironmentName) &&
                !environment.IsEnvironment("Testing"))
            {
                throw new InvalidOperationException(
                    "APP_B_AUTH_MODE=disabled is allowed only in the LocalCompose or Testing environment.");
            }

            return new AppBAuthenticationSettings(mode, DefaultAudience, string.Empty);
        }

        var audience = configuration["APP_B_TOKEN_AUDIENCE"]?.Trim();
        if (string.IsNullOrEmpty(audience))
        {
            audience = DefaultAudience;
        }
        else if (!string.Equals(audience, DefaultAudience, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"APP_B_TOKEN_AUDIENCE must be {DefaultAudience}.");
        }

        var projectId = configuration["GOOGLE_CLOUD_PROJECT"]?.Trim();
        if (!IsValidProjectId(projectId))
        {
            throw new InvalidOperationException(
                "GOOGLE_CLOUD_PROJECT must be a valid Google Cloud project ID in google-id-token mode.");
        }

        var requiredCallerEmail = $"{CallerEmailPrefix}{projectId}{CallerEmailSuffix}";
        var expectedCallerEmail = configuration["APP_A_IDENTITY_EMAIL"]?.Trim();
        if (!string.Equals(
            expectedCallerEmail,
            requiredCallerEmail,
            StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "APP_A_IDENTITY_EMAIL must exactly match the currency-app-a-caller service account for GOOGLE_CLOUD_PROJECT.");
        }

        return new AppBAuthenticationSettings(mode, audience, requiredCallerEmail);
    }

    private static bool IsValidProjectId(string? projectId)
    {
        if (string.IsNullOrEmpty(projectId))
        {
            return false;
        }

        return projectId.Length is >= 6 and <= 30 &&
            projectId[0] is >= 'a' and <= 'z' &&
            projectId[^1] is (>= 'a' and <= 'z') or (>= '0' and <= '9') &&
            projectId.All(character =>
                character is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-');
    }
}

public sealed record GoogleIdTokenClaims(
    string? Issuer,
    IReadOnlyList<string> Audiences,
    long? IssuedAtUnixSeconds,
    long? ExpirationUnixSeconds,
    long? NotBeforeUnixSeconds,
    string? Email,
    bool EmailVerified);

public enum GoogleIdTokenVerificationStatus
{
    Valid,
    InvalidToken,
    VerifierUnavailable,
}

public sealed record GoogleIdTokenVerificationResult(
    GoogleIdTokenVerificationStatus Status,
    GoogleIdTokenClaims? Claims)
{
    public bool Succeeded =>
        Status == GoogleIdTokenVerificationStatus.Valid && Claims is not null;

    public static GoogleIdTokenVerificationResult InvalidToken { get; } =
        new(GoogleIdTokenVerificationStatus.InvalidToken, null);

    public static GoogleIdTokenVerificationResult VerifierUnavailable { get; } =
        new(GoogleIdTokenVerificationStatus.VerifierUnavailable, null);

    public static GoogleIdTokenVerificationResult Valid(GoogleIdTokenClaims claims) =>
        new(GoogleIdTokenVerificationStatus.Valid, claims);
}

public interface IGoogleJsonWebSignatureValidator
{
    Task<GoogleJsonWebSignature.Payload> ValidateAsync(
        string token,
        string audience,
        CancellationToken cancellationToken);
}

public sealed class GoogleJsonWebSignatureValidator : IGoogleJsonWebSignatureValidator
{
    private static readonly TimeSpan IssuedAtTolerance = TimeSpan.FromSeconds(30);

    public async Task<GoogleJsonWebSignature.Payload> ValidateAsync(
        string token,
        string audience,
        CancellationToken cancellationToken)
    {
        var validation = GoogleJsonWebSignature.ValidateAsync(
            token,
            new GoogleJsonWebSignature.ValidationSettings
            {
                Audience = [audience],
                IssuedAtClockTolerance = IssuedAtTolerance,
                ExpirationTimeClockTolerance = TimeSpan.Zero,
            });

        return await validation.WaitAsync(cancellationToken);
    }
}

public interface IGoogleIdTokenVerifier
{
    Task<GoogleIdTokenVerificationResult> VerifyAsync(
        string token,
        string audience,
        CancellationToken cancellationToken);
}

public sealed class GoogleIdTokenVerifier(
    IGoogleJsonWebSignatureValidator signatureValidator) : IGoogleIdTokenVerifier
{
    public async Task<GoogleIdTokenVerificationResult> VerifyAsync(
        string token,
        string audience,
        CancellationToken cancellationToken)
    {
        try
        {
            var payload = await signatureValidator.ValidateAsync(
                token,
                audience,
                cancellationToken);

            return GoogleIdTokenVerificationResult.Valid(new GoogleIdTokenClaims(
                payload.Issuer,
                payload.AudienceAsList?.ToArray() ?? [],
                payload.IssuedAtTimeSeconds,
                payload.ExpirationTimeSeconds,
                payload.NotBeforeTimeSeconds,
                payload.Email,
                payload.EmailVerified));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is InvalidJwtException or FormatException)
        {
            // Invalid token details can include attacker-controlled input, so do not log them.
            return GoogleIdTokenVerificationResult.InvalidToken;
        }
        catch (Exception)
        {
            // Certificate retrieval or verifier failures fail closed without exposing details.
            return GoogleIdTokenVerificationResult.VerifierUnavailable;
        }
    }
}

public sealed record CallerAuthenticationResult(bool Succeeded, string ErrorType)
{
    public static CallerAuthenticationResult Accepted { get; } = new(true, string.Empty);

    public static CallerAuthenticationResult Rejected(string errorType) =>
        new(false, errorType);
}

public sealed class AppACallerClaimPolicy(
    AppBAuthenticationSettings settings,
    TimeProvider timeProvider)
{
    private const long IssuedAtToleranceSeconds = 30;
    private static readonly string[] GoogleIssuers =
    [
        "accounts.google.com",
        "https://accounts.google.com",
    ];

    public CallerAuthenticationResult Validate(GoogleIdTokenClaims claims)
    {
        if (!GoogleIssuers.Contains(claims.Issuer, StringComparer.Ordinal))
        {
            return CallerAuthenticationResult.Rejected("token_issuer_invalid");
        }

        if (claims.Audiences.Count != 1 ||
            !string.Equals(claims.Audiences[0], settings.Audience, StringComparison.Ordinal))
        {
            return CallerAuthenticationResult.Rejected("token_audience_invalid");
        }

        var now = timeProvider.GetUtcNow().ToUnixTimeSeconds();
        if (!claims.IssuedAtUnixSeconds.HasValue ||
            !claims.ExpirationUnixSeconds.HasValue ||
            claims.IssuedAtUnixSeconds.Value > now + IssuedAtToleranceSeconds ||
            claims.ExpirationUnixSeconds.Value <= now ||
            claims.ExpirationUnixSeconds.Value <= claims.IssuedAtUnixSeconds.Value ||
            (claims.NotBeforeUnixSeconds.HasValue &&
                claims.NotBeforeUnixSeconds.Value > now + IssuedAtToleranceSeconds))
        {
            return CallerAuthenticationResult.Rejected("token_lifetime_invalid");
        }

        if (string.IsNullOrWhiteSpace(claims.Email))
        {
            return CallerAuthenticationResult.Rejected("caller_email_missing");
        }

        if (!claims.EmailVerified)
        {
            return CallerAuthenticationResult.Rejected("caller_email_unverified");
        }

        if (!string.Equals(
            claims.Email,
            settings.ExpectedCallerEmail,
            StringComparison.Ordinal))
        {
            return CallerAuthenticationResult.Rejected("caller_identity_invalid");
        }

        return CallerAuthenticationResult.Accepted;
    }
}

public interface IAppBRequestAuthenticator
{
    Task<CallerAuthenticationResult> AuthenticateAsync(
        HttpRequest request,
        CancellationToken cancellationToken);
}

public sealed class AppBRequestAuthenticator(
    AppBAuthenticationSettings settings,
    IGoogleIdTokenVerifier tokenVerifier,
    AppACallerClaimPolicy claimPolicy) : IAppBRequestAuthenticator
{
    private const string BearerPrefix = "Bearer ";
    private const int MaximumTokenLength = 16 * 1024;

    public async Task<CallerAuthenticationResult> AuthenticateAsync(
        HttpRequest request,
        CancellationToken cancellationToken)
    {
        if (settings.Mode == AppBAuthenticationMode.Disabled)
        {
            return CallerAuthenticationResult.Accepted;
        }

        var authorizationValues = request.Headers.Authorization;
        if (authorizationValues.Count == 0)
        {
            return CallerAuthenticationResult.Rejected("authorization_missing");
        }

        if (authorizationValues.Count != 1)
        {
            return CallerAuthenticationResult.Rejected("authorization_duplicate");
        }

        var authorization = authorizationValues[0];
        if (string.IsNullOrEmpty(authorization) ||
            !authorization.StartsWith(BearerPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return CallerAuthenticationResult.Rejected("authorization_malformed");
        }

        var token = authorization[BearerPrefix.Length..];
        if (token.Length == 0 ||
            token.Length > MaximumTokenLength ||
            token.Contains(',', StringComparison.Ordinal) ||
            token.Any(char.IsWhiteSpace))
        {
            return CallerAuthenticationResult.Rejected("authorization_malformed");
        }

        var verification = await tokenVerifier.VerifyAsync(
            token,
            settings.Audience,
            cancellationToken);
        if (verification.Status == GoogleIdTokenVerificationStatus.VerifierUnavailable)
        {
            return CallerAuthenticationResult.Rejected("token_verifier_unavailable");
        }

        if (!verification.Succeeded || verification.Claims is null)
        {
            return CallerAuthenticationResult.Rejected("token_validation_failed");
        }

        return claimPolicy.Validate(verification.Claims);
    }
}
