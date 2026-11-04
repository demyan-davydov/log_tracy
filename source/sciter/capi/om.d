module sciter.capi.om;

struct som_passport_t;

alias som_atom_t = ulong;

struct som_asset_t
{
    som_asset_class_t* isa;
}

struct som_asset_class_t
{
    long function(som_asset_t* thing) asset_add_ref;
    long function(som_asset_t* thing) asset_release;
    long function(som_asset_t* thing, const(char)* name, void** result) asset_get_interface;
    som_passport_t* function(som_asset_t* thing) asset_get_passport;
}
