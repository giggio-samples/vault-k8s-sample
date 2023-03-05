using MongoDB.Driver;

namespace VaultApi;
public class MongoStaticClientFactory : IMongoClientFactory
{
    private readonly ValueTask<MongoClient> mongoClientTask;

    public MongoStaticClientFactory(string connectionString) =>
        mongoClientTask = new ValueTask<MongoClient>(new MongoClient(connectionString));

    public ValueTask<MongoClient> CreateAsync() => mongoClientTask;

    public Task ResetConnectionAsync() => throw new NotSupportedException();

    public ValueTask<bool> RevokeAsync() => throw new NotSupportedException();
}
