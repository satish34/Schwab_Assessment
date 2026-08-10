using System.Text.Json;
using AppB;

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(options => options.AddServerHeader = false);
builder.WebHost.UseUrls(
    Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "http://0.0.0.0:8080");

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
});
builder.Services.AddSingleton(sp => AppIdentity.FromConfiguration(
    sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton<StructuredLogWriter>();
builder.Services.AddSingleton<ExchangeRateProvider>();
builder.Services.AddSingleton<FaultSettingsProvider>();
builder.Services.AddSingleton<IFaultSettingsProvider>(sp =>
    sp.GetRequiredService<FaultSettingsProvider>());
builder.Services.AddHostedService(sp => sp.GetRequiredService<FaultSettingsProvider>());

var app = builder.Build();

app.MapGet("/health/live", () => Results.Ok(new HealthResponse("UP", "app-b-engine")));
app.MapGet("/health/ready", () => Results.Ok(new HealthResponse("UP", "app-b-engine")));
app.MapGet("/internal/exchange-rates", ExchangeRatesEndpoint.HandleAsync);

app.Services.GetRequiredService<StructuredLogWriter>().WriteSchemaSeed();

app.Run();

public partial class Program;
