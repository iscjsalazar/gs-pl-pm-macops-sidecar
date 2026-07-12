# Imagen de la API .NET 10 (PL.PM.Bootstrapper.Api) para el camino E2E.
# La construye el aprovisionamiento por slots (lib/worktrees.sh) en el docker de macdata; el contexto de build es la raíz
# de la solución rsync-eada (PM_REMOTE_SOLUTION_DIR). Se pasa por stdin (docker build -f-), por lo que este
# archivo NO se coloca dentro del árbol de la solución (frontera wrapper-solución).
#
# COPY selectivo: solo las entradas de build (global.json, Directory.*.props, src/); evita arrastrar
# containers/ y mantiene la imagen y el contexto livianos sin requerir un .dockerignore en la solución.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Manifiestos primero: maximiza el cache de capas del restore ante cambios de código.
COPY global.json Directory.Build.props Directory.Packages.props ./
COPY src/ ./src/
RUN dotnet publish src/PL.PM.Bootstrapper.Api/PL.PM.Bootstrapper.Api.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./
# Kestrel escucha en todas las interfaces del contenedor; el puerto del host lo mapea 'docker run -p'.
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "PL.PM.Bootstrapper.Api.dll"]
