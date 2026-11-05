module ui.search_chips;

//! The chips of a search query as the search editor of the script sends them:
//! a JSON array of {"text", "isRegex", "ignoreCase"} (resources/search-query.js).
//! The same form keeps the queries of a file in the settings (its search history).
//! Apart from the window so it can be tested.

import log_core.search_filter : SearchChip;
import std.json : JSONException, JSONType, JSONValue;

//! @brief Reads the chips of a query sent by the script.
//! @throws Exception if `json` is not an array of chips
SearchChip[] chipsFromJson(string json)
{
    import std.json : parseJSON;

    return chipsFromJson(parseJSON(json));
}

//! ditto, of parsed JSON
SearchChip[] chipsFromJson(const JSONValue json)
{
    SearchChip[] chips;
    foreach (const ref item; json.array) // throws if not an array
    {
        if (item.type != JSONType.object)
            throw new JSONException("a chip is not an object");
        chips ~= SearchChip(item["text"].str, flag(item, "isRegex"), flag(item, "ignoreCase"));
    }
    return chips;
}

//! @brief The chips of a query in the form the script sends them
JSONValue chipsToJson(const(SearchChip)[] chips)
{
    JSONValue[] items;
    foreach (const ref chip; chips)
        items ~= JSONValue(["text": JSONValue(chip.text), "isRegex": JSONValue(chip.isRegex),
            "ignoreCase": JSONValue(chip.ignoreCase)]);
    return JSONValue(items);
}

private bool flag(const ref JSONValue chip, string name)
{
    return chip[name].boolean; // throws if missing or not a boolean
}

@("chipsFromJson: the chips in their order, with their type and case")
unittest
{
    const chips = chipsFromJson(`[{"text": "a|b", "isRegex": false, "ignoreCase": true},
        {"text": "time(out|d)", "isRegex": true, "ignoreCase": false}, {"text": " ", "isRegex": false, "ignoreCase": false}]`);
    assert(chips == [SearchChip("a|b", false, true), SearchChip("time(out|d)", true, false), SearchChip(" ")]);
    assert(chipsFromJson(`[]`).length == 0);
}

@("chipsFromJson: anything but an array of chips is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown(chipsFromJson(`{"text": "a"}`), "not an array");
    assertThrown(chipsFromJson(`[{"isRegex": false, "ignoreCase": false}]`), "no text");
    assertThrown(chipsFromJson(`[{"text": 1, "isRegex": false, "ignoreCase": false}]`), "a text that isn't a string");
    assertThrown(chipsFromJson(`[{"text": "a", "isRegex": "yes", "ignoreCase": false}]`), "a flag that isn't a boolean");
    assertThrown(chipsFromJson(`[`), "not JSON");
}

@("chipsToJson: the form chipsFromJson reads")
unittest
{
    const chips = [SearchChip("a|b", false, true), SearchChip(`x\d+`, true, false)];
    assert(chipsFromJson(chipsToJson(chips)) == chips);
    assert(chipsToJson(chips)[0]["text"].str == "a|b");
}
