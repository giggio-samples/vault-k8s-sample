namespace VaultApi;
public static class MongoExtensions
{
    public static void AddMongo(this IServiceCollection services, string? connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            services.AddSingleton<VaultClientFactory>();
            services.AddSingleton<IMongoClientFactory, MongoClientFactory>();
        }
        else
        {
            services.AddSingleton<IMongoClientFactory>(new MongoStaticClientFactory(connectionString));
        }
    }
}
