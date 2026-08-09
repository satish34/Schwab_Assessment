FROM mcr.microsoft.com/dotnet/sdk:8.0.423-bookworm-slim AS build
WORKDIR /src

COPY src/AppB/AppB.csproj src/AppB/
RUN dotnet restore src/AppB/AppB.csproj

COPY src/AppB/ src/AppB/
RUN dotnet publish src/AppB/AppB.csproj \
    --configuration Release \
    --no-restore \
    --output /app/publish \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0.29-bookworm-slim AS runtime
WORKDIR /app

RUN groupadd --gid 10001 appgroup \
    && useradd --uid 10001 --gid appgroup --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=build --chown=10001:10001 /app/publish .

ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_EnableDiagnostics=0

USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["dotnet", "AppB.dll"]
