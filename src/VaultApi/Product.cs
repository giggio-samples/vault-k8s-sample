using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;

namespace VaultApi;
public class Product
{
    public ObjectId Id { get; set; }
    [BsonElement("name")]
    public string? Name { get; set; }
}
