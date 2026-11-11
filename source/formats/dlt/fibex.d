//! Reads a FIBEX file: the descriptions of non-verbose DLT messages by message ID.
//! Nothing imports it yet.
module formats.dlt.fibex;

import std.file;
import std.stdio;
import std.string;
import std.conv;
import std.algorithm;
import std.array;

/// Maps Message ID to Description
class FibexParser
{
    private string[uint] _idMap;

    /// Load and parse a FIBEX/XML file
    void load(string path)
    {
        try
        {
            const string s = cast(string) std.file.read(path);

            // Manual scanning for ID and Description mappings to avoid std.xml dependency
            // We look for patterns like:
            // ID="..." ... Text="..."
            // or <ID>...</ID> with nearby <DESC>...</DESC>

            size_t cursor = 0;
            while (cursor < s.length)
            {
                // Find <message or <PDU or <FRAME or <ELEMENT
                const ptrdiff_t startTag = s.indexOf("<", cursor);
                if (startTag == -1)
                    break;

                cursor = startTag + 1;
                const ptrdiff_t tagEnd = s.indexOf(">", startTag);
                if (tagEnd == -1)
                    break;

                const string fullTag = s[startTag .. tagEnd + 1];

                // Strategy: Find an ID, then find a description nearby.
                // IDs can be in id="..." attribute OR <ID>...</ID> tag.

                string idStr;
                const ptrdiff_t idAttr = fullTag.indexOf("id=\"");
                if (idAttr != -1)
                {
                    const size_t idValStart = idAttr + 4;
                    const ptrdiff_t idValEnd = fullTag.indexOf("\"", idValStart);
                    if (idValEnd != -1)
                        idStr = fullTag[idValStart .. idValEnd];
                }

                if (idStr.empty)
                {
                    // Look for <ID> tag within 100 chars
                    const ptrdiff_t idTag = s.indexOf("<ID>", startTag);
                    if (idTag != -1 && idTag - startTag < 100)
                    {
                        const size_t start = idTag + 4;
                        const ptrdiff_t end = s.indexOf("</ID>", start);
                        if (end != -1)
                            idStr = s[start .. end].strip();
                    }
                }

                if (!idStr.empty)
                {
                    try
                    {
                        uint id;
                        const string cleanId = idStr.strip().toLower();
                        if (cleanId.startsWith("0x"))
                            id = to!uint(cleanId[2 .. $], 16);
                        else if (cleanId.startsWith("x"))
                            id = to!uint(cleanId[1 .. $], 16);
                        else
                            id = to!uint(cleanId);

                        // Find Description: text="..." OR <description> OR <DESC> OR <desc>
                        string desc;
                        const ptrdiff_t textAttr = fullTag.indexOf("text=\"");
                        if (textAttr != -1)
                        {
                            const size_t txtStart = textAttr + 6;
                            const ptrdiff_t txtEnd = fullTag.indexOf("\"", txtStart);
                            if (txtEnd != -1)
                                desc = fullTag[txtStart .. txtEnd];
                        }

                        if (desc.empty)
                        {
                            const string[] descTags = [
                                "<description>", "<DESC>", "<desc>", "<LONG-NAME>"
                            ];
                            ptrdiff_t nearestPos = -1;
                            string nearestTag;

                            foreach (t; descTags)
                            {
                                const ptrdiff_t dPos = s.indexOf(t, startTag);
                                if (dPos != -1 && dPos - startTag < 500)
                                {
                                    if (nearestPos == -1 || dPos < nearestPos)
                                    {
                                        nearestPos = dPos;
                                        nearestTag = t;
                                    }
                                }
                            }

                            if (nearestPos != -1)
                            {
                                const size_t dStart = nearestPos + nearestTag.length;
                                const string endT = "</" ~ nearestTag[1 .. $];
                                const ptrdiff_t dEnd = s.indexOf(endT, dStart);
                                if (dEnd != -1)
                                {
                                    desc = s[dStart .. dEnd].strip();
                                    if (dEnd + endT.length > cursor)
                                        cursor = dEnd + endT.length;
                                }
                            }
                        }

                        if (!desc.empty)
                        {
                            _idMap[id] = desc;
                        }
                    }
                    catch (Exception e)
                    {
                    }
                }

                if (cursor <= tagEnd)
                    cursor = tagEnd + 1;
            }

            writeln("FIBEX Loaded: ", _idMap.length, " IDs mapped.");
        }
        catch (Exception e)
        {
            writeln("Error loading FIBEX: ", e.msg);
        }
    }

    /// Get description for a message ID
    string getDescription(uint id) const
    {
        return _idMap.get(id, null);
    }

    bool hasId(uint id) const pure nothrow @nogc
    {
        return (id in _idMap) !is null;
    }
}

unittest
{
    import std.file;
    import std.path;

    writeln("Running FIBEX Parser Tests...");

    string content = q"{
<FRAME>
    <ID>123</ID> 
    <DESC>Test Message</DESC>
    <pdu id="456">
        <description>Another Message</description>
    </pdu>
    <message id="789" text="Attribute Style" />
    <element id="101">
        <LONG-NAME>Long Name Style</LONG-NAME>
    </element>
    <message id="0xABC" text="Hex Style 1" />
    <message id="xDEF" text="Hex Style 2" />
</FRAME>
    }";

    string tempFile = "temp_test.xml";
    std.file.write(tempFile, content);

    scope (exit)
    {
        if (exists(tempFile))
            std.file.remove(tempFile);
    }

    FibexParser parser = new FibexParser();
    parser.load(tempFile);

    assert(parser.getDescription(123) == "Test Message");
    assert(parser.getDescription(456) == "Another Message");
    assert(parser.getDescription(789) == "Attribute Style");
    assert(parser.getDescription(101) == "Long Name Style");
    assert(parser.getDescription(0xABC) == "Hex Style 1");
    assert(parser.getDescription(0xDEF) == "Hex Style 2");

    writeln("FIBEX Tests Passed.");
}
