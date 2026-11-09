module formats.can.frame;

//! What the CAN trace formats (candump, Vector ASC) share: the fields of a
//! frame in LogMessage, its columns, and the data bytes as text.

import log_core.log_format : ColumnInfo, ColumnKind;
import log_core.log_message : TimeKind;

//! Field indexes of a CAN frame in LogMessage
enum CanField : ubyte
{
    Channel, // text: can0, 1...
    Id, // number: the identifier, 11 or 29 bits (or with the error flag)
    Dir, // text: Rx, Tx (Vector ASC)
    Type, // number: CanFrameType
    Dlc, // number: the bytes of data
}

//! The most data bytes of a frame: CAN FD
enum size_t maxData = 64;

//! The kind of a record of a CAN trace
enum CanFrameType : ubyte
{
    Can,
    CanFd,
    Remote,
    Error,
    Event, // anything else with a time: start of measurement, statistics...
}

//! The columns of a CAN trace
//! @param timeKind - how the format writes its time
//! @param withDir - the trace tells received from sent frames
ColumnInfo[] canColumns(TimeKind timeKind, bool withDir) pure
{
    ColumnInfo[] columns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, timeKind),
        ColumnInfo("channel", "Channel", ColumnKind.Text, CanField.Channel),
        ColumnInfo("id", "ID", ColumnKind.Hex, CanField.Id),
    ];
    if (withDir)
        columns ~= ColumnInfo("dir", "Dir", ColumnKind.Text, CanField.Dir);
    columns ~= [
        // Error frames are colored like errors
        ColumnInfo("type", "Type", ColumnKind.Enum, CanField.Type, TimeKind.None, 0,
            ["CAN", "CAN FD", "Remote", "Error", "Event"], true),
        ColumnInfo("dlc", "DLC", ColumnKind.Integer, CanField.Dlc),
        ColumnInfo("payload", "Data", ColumnKind.Payload),
    ];
    return columns;
}

//! @brief Writes data bytes as upper case hex pairs separated by spaces
//! ("DE AD BE EF") into `out_`
//! @returns the text written, a slice of `out_`
char[] hexBytes(const(ubyte)[] bytes, char[] out_) pure nothrow @nogc @safe
{
    static immutable char[16] digits = "0123456789ABCDEF";
    size_t n = 0;
    foreach (i, b; bytes)
    {
        const needed = i == 0 ? 2 : 3;
        if (n + needed > out_.length)
            break;
        if (i)
            out_[n++] = ' ';
        out_[n++] = digits[b >> 4];
        out_[n++] = digits[b & 0xF];
    }
    return out_[0 .. n];
}

@("CAN frame: the columns, the type colored by the level")
unittest
{
    string[] ids(bool withDir)
    {
        string[] result;
        foreach (column; canColumns(TimeKind.Absolute, withDir))
            result ~= column.id;
        return result;
    }

    assert(ids(false) == ["time", "channel", "id", "type", "dlc", "payload"]);
    assert(ids(true) == ["time", "channel", "id", "dir", "type", "dlc", "payload"]);
    foreach (column; canColumns(TimeKind.Local, true))
    {
        assert(column.byLevel == (column.id == "type"), column.id);
        if (column.id == "time")
            assert(column.timeKind == TimeKind.Local);
        if (column.id == "id")
            assert(column.kind == ColumnKind.Hex);
        if (column.id == "type")
            assert(column.labels == ["CAN", "CAN FD", "Remote", "Error", "Event"]);
    }
}

@("CAN frame: data bytes as hex pairs")
unittest
{
    char[64] buffer;
    assert(hexBytes([0xDE, 0xAD, 0xBE, 0xEF, 0x00], buffer[]) == "DE AD BE EF 00");
    assert(hexBytes([], buffer[]) == "");
    assert(hexBytes([0x01], buffer[0 .. 2]) == "01", "fits exactly");
}
