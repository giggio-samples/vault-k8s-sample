using VaultApi;
using MongoDB.Driver;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddMongo(builder.Configuration.GetConnectionString("Mongo"));
builder.Services.AddHealthChecks();
builder.Services.Configure<VaultConfiguration>(builder.Configuration.GetSection("Vault"));
var app = builder.Build();

app.MapGet("/", () => "We are live!");
app.MapGet("/products", async (IMongoClientFactory mongoClientFactory) =>
{
    var productsCollection = await CreateCollection(mongoClientFactory);
    var productsCursor = await productsCollection.FindAsync(FilterDefinition<Product>.Empty);
    var products = await productsCursor.ToListAsync();
    return products;
});
app.MapGet("/products/add", async (IMongoClientFactory mongoClientFactory) =>
{
    var productsCollection = await CreateCollection(mongoClientFactory);
    var product = new Product { Name = DateTime.Now.ToString() };
    await productsCollection.InsertOneAsync(product);
    return product;
});
app.MapGet("/revoke", async (IMongoClientFactory mongoClientFactory) => await mongoClientFactory.RevokeAsync());
app.MapGet("/resetconnection", async (IMongoClientFactory mongoClientFactory) => await mongoClientFactory.ResetConnectionAsync());
app.MapHealthChecks("/health");

app.Run();

async ValueTask<IMongoCollection<Product>> CreateCollection(IMongoClientFactory mongoClientFactory)
{
    var client = await mongoClientFactory.CreateAsync();
    var database = client.GetDatabase("appdb");
    var products = database.GetCollection<Product>("products");
    return products;
}