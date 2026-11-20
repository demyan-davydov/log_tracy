//! The chips of a search query as the search editor of the script sends them:
//! a JSON array of {"text", "isRegex", "matchCase", "color"} (resources/pane-commands.js, `runSearch`).
//! The same form, without the colors, keeps the queries of a file in the settings (its search history).
//! Apart from the window so it can be tested.
module ui.search_chips;

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
        chips ~= SearchChip(item["text"].str, flag(item, "isRegex"), !flag(item, "matchCase"));
    }
    return chips;
}

//! A query the script starts: its chips and the match color of each, by its place (`LogPalette.match`, the script's
//! `matchColorClass`): what a chip finds is colored by its color, which is the chip's own, not its place in the query
struct ChipQuery
{
    SearchChip[] chips;
    uint[] colors;
}

//! @brief Reads a query the script starts: a chip without a color gets the one of its place
//! @throws Exception if `json` is not an array of chips, or a color is not a number of 0 or more
ChipQuery queryFromJson(string json)
{
    import std.json : parseJSON;

    const parsed = parseJSON(json);
    ChipQuery query;
    query.chips = chipsFromJson(parsed);
    foreach (i, const ref item; parsed.array)
    {
        const color = "color" in item.object;
        if (color is null)
            query.colors ~= cast(uint) i;
        else if (color.type == JSONType.uinteger || (color.type == JSONType.integer && color.integer >= 0))
            query.colors ~= cast(uint) color.integer;
        else
            throw new JSONException("the color of a chip is not a number of 0 or more");
    }
    return query;
}

//! @brief The chips of a query in the form the script sends them
JSONValue chipsToJson(const(SearchChip)[] chips)
{
    JSONValue[] items;
    foreach (const ref chip; chips)
        items ~= JSONValue(["text": JSONValue(chip.text), "isRegex": JSONValue(chip.isRegex),
            "matchCase": JSONValue(!chip.ignoreCase)]);
    return JSONValue(items);
}

private bool flag(const ref JSONValue chip, string name)
{
    return chip[name].boolean; // throws if missing or not a boolean
}

@("chipsFromJson: the chips in their order, with their type and case")
unittest
{
    const chips = chipsFromJson(`[{"text": "a|b", "isRegex": false, "matchCase": false},
        {"text": "time(out|d)", "isRegex": true, "matchCase": true}, {"text": " ", "isRegex": false, "matchCase": true}]`);
    assert(chips == [SearchChip("a|b", false, true), SearchChip("time(out|d)", true, false), SearchChip(" ")]);
    assert(chipsFromJson(`[]`).length == 0);
}

@("chipsFromJson: anything but an array of chips is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown(chipsFromJson(`{"text": "a"}`), "not an array");
    assertThrown(chipsFromJson(`[{"isRegex": false, "matchCase": true}]`), "no text");
    assertThrown(chipsFromJson(`[{"text": 1, "isRegex": false, "matchCase": true}]`), "a text that isn't a string");
    assertThrown(chipsFromJson(`[{"text": "a", "isRegex": "yes", "matchCase": true}]`), "a flag that isn't a boolean");
    assertThrown(chipsFromJson(`[{"text": "a", "isRegex": false, "ignoreCase": true}]`), "no matchCase");
    assertThrown(chipsFromJson(`[`), "not JSON");
}

@("queryFromJson: each chip with its color, a chip without one with its place")
unittest
{
    const query = queryFromJson(`[{"text": "a", "isRegex": false, "matchCase": false, "color": 5},
        {"text": "b", "isRegex": false, "matchCase": false}, {"text": "c", "isRegex": true, "matchCase": true, "color": 2}]`);
    assert(query.chips == [SearchChip("a", false, true), SearchChip("b", false, true), SearchChip("c", true, false)]);
    assert(query.colors == [5, 1, 2]);
}

@("queryFromJson: a color that is not a number of 0 or more is refused")
unittest
{
    import std.exception : assertThrown;

    assertThrown(queryFromJson(`[{"text": "a", "isRegex": false, "matchCase": false, "color": "red"}]`));
    assertThrown(queryFromJson(`[{"text": "a", "isRegex": false, "matchCase": false, "color": -1}]`));
    assertThrown(queryFromJson(`[{"text": "a", "isRegex": false, "matchCase": false, "color": 1.5}]`));
}

@("chipsToJson: the form chipsFromJson reads")
unittest
{
    const chips = [SearchChip("a|b", false, true), SearchChip(`x\d+`, true, false)];
    assert(chipsFromJson(chipsToJson(chips)) == chips);
    assert(chipsToJson(chips)[0]["text"].str == "a|b");
    assert(!chipsToJson(chips)[0]["matchCase"].boolean && chipsToJson(chips)[1]["matchCase"].boolean);
}
