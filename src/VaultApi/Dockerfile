FROM mcr.microsoft.com/dotnet/aspnet:7.0 AS base
WORKDIR /app
RUN adduser -u 5678 --disabled-password --gecos "" appuser && chown -R appuser /app
EXPOSE 80
ENV ASPNETCORE_URLS=http://+:80
ENTRYPOINT ["dotnet", "VaultApi.dll"]
USER appuser

FROM mcr.microsoft.com/dotnet/sdk:7.0 AS build
WORKDIR /src
COPY ["src/VaultApi/VaultApi.csproj", "src/VaultApi/"]
RUN dotnet restore "src/VaultApi/VaultApi.csproj"
COPY . .
WORKDIR "/src/src/VaultApi"
RUN dotnet publish "VaultApi.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
COPY --from=build /app/publish .
