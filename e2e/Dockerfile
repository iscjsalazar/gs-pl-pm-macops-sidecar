# Imagen de la API .NET 10 (PL.PM.Bootstrapper.Api) para el camino E2E.
# La construye el aprovisionamiento por slots (lib/worktrees.sh) en el docker de macdata; el contexto de build es la raíz
# de la solución rsync-eada (PM_REMOTE_SOLUTION_DIR). Se pasa por stdin (docker build -f-), por lo que este
# archivo NO se coloca dentro del árbol de la solución (frontera wrapper-solución).
#
# COPY selectivo: solo las entradas de build (global.json, Directory.*.props, src/); evita arrastrar
# containers/ y mantiene la imagen y el contexto livianos sin requerir un .dockerignore en la solución.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Capacidad test-only del gate login-skip-password. Default false: el slot nace sin el gate y la
# perilla se pide explicitamente (make wt-up ... LOGINSKIP=1).
ARG LOGIN_SKIP_PASSWORD_TEST_CAPABILITY=false
# Manifiestos primero: maximiza el cache de capas del restore ante cambios de código.
COPY global.json Directory.Build.props Directory.Packages.props ./
COPY src/ ./src/
RUN dotnet publish src/PL.PM.Bootstrapper.Api/PL.PM.Bootstrapper.Api.csproj -c Release \
      -p:LoginSkipPasswordTestCapability=$LOGIN_SKIP_PASSWORD_TEST_CAPABILITY -o /app
# El marcador del ensamblado publicado es la unica prueba de la capacidad REAL; el build corta si el
# artefacto no coincide con lo pedido (una propiedad renombrada o ignorada no pasa inadvertida).
RUN set -eu; \
    if grep -qa 'LoginSkipPasswordTestCapabilityMarker' /app/PL.PM.Catalogs.Infrastructure.dll; \
      then found=true; else found=false; fi; \
    [ "$found" = "$LOGIN_SKIP_PASSWORD_TEST_CAPABILITY" ] \
      || { echo "capacidad pedida=$LOGIN_SKIP_PASSWORD_TEST_CAPABILITY, marcador en el artefacto=$found" >&2; exit 1; }

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
# Kestrel escucha en todas las interfaces del contenedor; el puerto del host lo mapea 'docker run -p'.
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "PL.PM.Bootstrapper.Api.dll"]
