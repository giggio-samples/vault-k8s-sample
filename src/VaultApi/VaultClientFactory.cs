using Microsoft.Extensions.Options;
using VaultSharp;
using VaultSharp.V1.AuthMethods.Kubernetes;

namespace VaultApi;
public class VaultClientFactory
{
    private const int expirationBufferInSeconds = 20; // todo: configure
    private readonly ILogger<VaultClientFactory> logger;
    private readonly string kubernetesRoleName;
    private KubernetesAuthMethodInfo authMethod;
    private BaseLease lease = BaseLease.Empty;
    private readonly string vaultServerUriWithPort = Environment.GetEnvironmentVariable("VAULT_PORT")?.Replace("tcp", "http") ?? throw new InvalidOperationException("VAULT_ADDR is not set");
    private VaultClient vaultClient;
    public VaultClientFactory(IOptions<VaultConfiguration> config, ILogger<VaultClientFactory> logger)
    {
        this.logger = logger ?? throw new ArgumentNullException(nameof(logger));
        kubernetesRoleName = config.Value.KubernetesRoleName ?? throw new ArgumentNullException(nameof(VaultConfiguration.KubernetesRoleName));
        var jwt = File.ReadAllText("/var/run/secrets/kubernetes.io/serviceaccount/token");
        authMethod = new KubernetesAuthMethodInfo(kubernetesRoleName, jwt);
        vaultClient = new VaultClient(new VaultClientSettings(vaultServerUriWithPort, authMethod));
    }

    public async ValueTask<VaultClient> GetVaultClientAsync()
    {
        if (lease.Requested)
        {
            if (lease.ShouldRenew)
            {
                logger.LogWarning($"Auth lease is about to expire at {lease.LeaseDate.DateWithTimeAndSeconds()}, so a new one will be generated...");
                var renewLoginAuthInfo = await vaultClient.V1.Auth.Token.RenewSelfAsync();
                lease = BaseLease.Create(renewLoginAuthInfo.LeaseDurationSeconds, renewLoginAuthInfo.Renewable);
                return vaultClient;
            }
            else if (lease.CanRenew)
            {
                logger.LogInformation($"The current auth lease will expire at {lease.Expiration.DateWithTimeAndSeconds()}.");
                return vaultClient;
            }
            else
            {
                if (lease.Expired)
                    logger.LogInformation($"The auth lease is expired, creating a new one...");
                else
                    logger.LogInformation($"The auth lease is not renewable, creating a new one...");
            }
        }
        else
        {
            logger.LogInformation($"A new auth lease will be generated...");
        }
        await vaultClient.V1.Auth.PerformImmediateLogin();
        var loginAuthInfo = vaultClient.Settings.AuthMethodInfo.ReturnedLoginAuthInfo;
        lease = BaseLease.Create(loginAuthInfo.LeaseDurationSeconds, loginAuthInfo.Renewable);
        return vaultClient;
    }
}
