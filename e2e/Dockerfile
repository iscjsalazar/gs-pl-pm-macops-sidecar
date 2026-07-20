# syntax=docker/dockerfile:1.7
# Imagen de la API .NET 10 (PL.PM.Bootstrapper.Api) para el camino E2E.
# La construye el aprovisionamiento por slots (lib/worktrees.sh) en el docker de macdata; el contexto de build es la raíz
# de la solución rsync-eada (PM_REMOTE_SOLUTION_DIR). Se pasa por stdin (docker build -f-), por lo que este
# archivo NO se coloca dentro del árbol de la solución (frontera wrapper-solución).
#
# COPY selectivo: solo las entradas de build (global.json, Directory.*.props, src/); evita arrastrar
# containers/ y mantiene la imagen y el contexto livianos sin requerir un .dockerignore en la solución.
#
# La directiva 'syntax=docker/dockerfile:1.7' habilita 'COPY --parents' (preserva la estructura de directorios de
# los .csproj emparejados) y 'RUN --mount=type=cache' (cache de paquetes NuGet compartida entre builds). Requiere
# BuildKit: el call-site del build exporta DOCKER_BUILDKIT=1 (lib/worktrees.sh).

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Capa de restore SEPARADA y cacheable. Primero los manifiestos (nunca los .cs): global.json + los Directory.*.props
# + todos los .csproj con su estructura de rutas (COPY --parents). Luego 'dotnet restore' con la cache de paquetes
# NuGet montada por BuildKit. Un cambio de solo-.cs no toca estos manifiestos, asi que la capa de restore sale
# CACHED (ac3) y las descargas de NuGet persisten en la cache mount entre builds.
COPY global.json Directory.Build.props Directory.Packages.props ./
COPY --parents src/**/*.csproj ./
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore src/PL.PM.Bootstrapper.Api/PL.PM.Bootstrapper.Api.csproj
# El codigo entra DESPUES del restore: un cambio de .cs invalida de aqui en adelante, no la capa de restore. El
# publish corre con --no-restore (reusa el restore de la capa previa) y monta la MISMA cache de paquetes NuGet
# (los paquetes restaurados viven en la cache mount, no en la capa: el publish debe montarla para resolverlos).
COPY src/ ./src/
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish src/PL.PM.Bootstrapper.Api/PL.PM.Bootstrapper.Api.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
# Kestrel escucha en todas las interfaces del contenedor; el puerto del host lo mapea 'docker run -p'.
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "PL.PM.Bootstrapper.Api.dll"]
