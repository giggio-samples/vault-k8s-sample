using MongoDB.Driver;

namespace VaultApi;

public interface IMongoClientFactory
{
    ValueTask<MongoClient> CreateAsync();
    ValueTask<bool> RevokeAsync();
    Task ResetConnectionAsync();
}
