function GetMongoCreds {
    vault read database/creds/webapp-role --format=json | ConvertFrom-Json
}

function ConnectMongo($x) {
    mongosh appdb --username $x.data.username --password $x.data.password
}
