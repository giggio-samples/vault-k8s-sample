using System.Diagnostics.CodeAnalysis;
using Microsoft.Extensions.Options;
using MongoDB.Driver;
using VaultSharp.Core;

namespace VaultApi;
public class MongoClientFactory : IMongoClientFactory
{
    private readonly string dbServer;
    private readonly string dbName;
    private readonly string mongoRoleName;
    private const int expirationBufferInSeconds = 20; // todo: configure
    private const int renewalInSeconds = 60; // todo: configure
    private readonly VaultClientFactory vaultClientFactory;
    private readonly ILogger<MongoClientFactory> logger;
    private Lease lease = Lease.Empty;
    private MongoClient? mongoClient;

    public MongoClientFactory(VaultClientFactory vaultClientFactory, IOptions<VaultConfiguration> config, ILogger<MongoClientFactory> logger)
    {
        this.vaultClientFactory = vaultClientFactory;
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
        dbServer = config.Value.DbServer ?? throw new ArgumentNullException(nameof(VaultConfiguration.DbServer));
        dbName = config.Value.DbName ?? throw new ArgumentNullException(nameof(VaultConfiguration.DbName));
        mongoRoleName = config.Value.MongoRoleName ?? throw new ArgumentNullException(nameof(VaultConfiguration.MongoRoleName));
        BaseLease.ExpirationBufferInSeconds = expirationBufferInSeconds;
    }

    [MemberNotNull(nameof(mongoClient))]
    public async ValueTask<MongoClient> CreateAsync()
    {
        if (mongoClient == null || lease.Expired)
            return await CreateNewMongoClientAsync();
        if (await RenewDbLeaseIfNeededAsync())
            return mongoClient;
        return await CreateNewMongoClientAsync();
    }

    [MemberNotNull(nameof(mongoClient))]
    private async ValueTask<MongoClient> CreateNewMongoClientAsync()
    {
        logger.LogInformation($"A new credential lease is going to be created.");
#pragma warning disable CS8774 // Member must have a non-null value when exiting, this is a bug in await, see: https://github.com/dotnet/csharplang/discussions/4994
        var vaultClient = await vaultClientFactory.GetVaultClientAsync();
        lease = Lease.Create(await vaultClient.V1.Secrets.Database.GetCredentialsAsync(mongoRoleName));
#pragma warning restore CS8774
        logger.LogWarning($"New credential lease created with user {lease.Username} at {lease.LeaseDate.DateWithTimeAndSeconds(showSeconds: false)}. The lease is set to expire in {lease.LeaseDurationSeconds} seconds at {lease.Expiration.DateWithTimeAndSeconds()}.");
        return mongoClient = new MongoClient($"mongodb://{lease.Username}:{lease.Password}@{dbServer}/{dbName}");
    }

    private async ValueTask<bool> RenewDbLeaseIfNeededAsync()
    {
        if (!lease.Requested)
            throw new InvalidOperationException("Lease not requested yet.");
        if (lease.ShouldRenew)
        {
            logger.LogInformation($"The credential lease (id ${lease.LeaseId}) is about to expire at {lease.Expiration.DateWithTimeAndSeconds()}. Renewing it...");
            var vaultClient = await vaultClientFactory.GetVaultClientAsync();
            try
            {
                lease = lease.FromRenewal(await vaultClient.V1.System.RenewLeaseAsync(lease.LeaseId, renewalInSeconds));
                if (lease.LeaseDurationSeconds < renewalInSeconds) // close to lease ttl
                {
                    logger.LogInformation($"The credential lease (id ${lease.LeaseId}) was renewed with a shorter duration of {lease.LeaseDurationSeconds} seconds, we are close to Max TTL. Creating a new one...");
                    return false;
                }
                else
                {
                    logger.LogInformation($"Credential lease renewed for user {lease.Username} at {lease.LeaseDate.DateWithTimeAndSeconds(showSeconds: false)}. The lease is set to expire in {lease.LeaseDurationSeconds} seconds at {lease.Expiration.DateWithTimeAndSeconds()}.");
                    return true;
                }
            }
            catch (VaultApiException ex)
            {
                logger.LogError(ex, $"The credential lease (id ${lease.LeaseId}) was lost.");
                ClearDbCredentials();
                return false;
            }
        }
        else if (lease.CanRenew)
        {
            logger.LogInformation($"The current credential lease will expire at {lease.Expiration.DateWithTimeAndSeconds()}.");
            return true;
        }
        else
        {
            if (lease.Expired)
                logger.LogInformation($"The lease is expired, creating a new one...");
            else
                logger.LogInformation($"The lease is not renewable, creating a new one...");
            return false;
        }
    }

    public async ValueTask<bool> RevokeAsync()
    {
        if (lease.Expired)
            return false;
        var vaultClient = await vaultClientFactory.GetVaultClientAsync();
        await vaultClient.V1.System.RevokeLeaseAsync(lease.LeaseId);
        ClearDbCredentials();
        return true;
    }

    public void ClearDbCredentials() => lease = Lease.Empty;

    public async Task ResetConnectionAsync()
    {
        if (lease.Requested)
        {
            logger.LogWarning($"Lease not requested yet.");
        }
        else
        {
            logger.LogWarning($"Resetting the lease. Lease id {lease.LeaseId} will be removed.");
            ClearDbCredentials();
            await CreateNewMongoClientAsync();
        }
    }
}
