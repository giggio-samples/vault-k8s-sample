using VaultSharp.V1.Commons;
using VaultSharp.V1.SecretsEngines;
using VaultSharp.V1.SystemBackend;

namespace VaultApi;

public record BaseLease(int LeaseDurationSeconds, bool Renewable, DateTime LeaseDate)
{
    public DateTime Expiration => LeaseDate.AddSeconds(LeaseDurationSeconds);
    public bool Expired => DateTime.Now > Expiration;
    public bool Requested => LeaseDate != DateTime.MinValue;
    public bool ShouldRenew => CanRenew && DateTime.Now > RenewalThreashold;
    public bool CanRenew => Renewable && !Expired;
    public DateTime RenewalThreashold => this.LeaseDate.AddSeconds(LeaseDurationSeconds - ExpirationBufferInSeconds);
    public static int ExpirationBufferInSeconds { get; set; }
    public static BaseLease Create(int leaseDurationSeconds, bool renewable) => new BaseLease(leaseDurationSeconds, renewable, DateTime.Now);
    public static BaseLease Empty => new BaseLease(0, false, DateTime.MinValue);

}

public record Lease(int LeaseDurationSeconds, bool Renewable, DateTime LeaseDate, string LeaseId, string Username, string Password)
    : BaseLease(LeaseDurationSeconds, Renewable, LeaseDate)
{
    public static Lease Create(Secret<UsernamePasswordCredentials> secret) =>
        new Lease(secret.LeaseDurationSeconds, secret.Renewable, DateTime.Now, secret.LeaseId, secret.Data.Username, secret.Data.Password);
    public Lease FromRenewal(Secret<RenewedLease> secret) =>
        new Lease(secret.LeaseDurationSeconds, secret.Renewable, DateTime.Now, secret.LeaseId, Username, Password);
    public static new Lease Empty => new Lease(0, false, DateTime.MinValue, string.Empty, string.Empty, string.Empty);
}