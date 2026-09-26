const std = @import("std");

//
// A JavaScript `Date` (milliseconds since the Unix epoch). Only the methods that are used are ported.
//
pub const Date = struct {
    // Milliseconds since 1970-01-01T00:00:00.000Z (the value of `date.getTime()`).
    epochMilliseconds: i64,

    //
    // Equivalent of `date.toISOString()`: formats the date as YYYY-MM-DDTHH:mm:ss.sssZ in UTC.
    // Years outside 0 to 9999 are not supported (JavaScript uses an expanded +YYYYYY format).
    //
    pub fn toISOString(self: Date, allocator: std.mem.Allocator) ![]const u8 {
        const milliseconds_per_day: i64 = 24 * 60 * 60 * 1000;
        const days = @divFloor(self.epochMilliseconds, milliseconds_per_day);
        const millisecond_of_day = @mod(self.epochMilliseconds, milliseconds_per_day);
        const civil_date = civilFromDays(days);
        const hours = @divFloor(millisecond_of_day, 60 * 60 * 1000);
        const minutes = @mod(@divFloor(millisecond_of_day, 60 * 1000), 60);
        const seconds = @mod(@divFloor(millisecond_of_day, 1000), 60);
        const milliseconds = @mod(millisecond_of_day, 1000);
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            @as(u64, @intCast(civil_date.year)),
            civil_date.month,
            civil_date.day,
            @as(u64, @intCast(hours)),
            @as(u64, @intCast(minutes)),
            @as(u64, @intCast(seconds)),
            @as(u64, @intCast(milliseconds)),
        });
    }
};

//
// A calendar date in the proleptic Gregorian calendar.
//
const CivilDate = struct {
    // The year.
    year: i64,

    // The month (1 to 12).
    month: u8,

    // The day of the month (1 to 31).
    day: u8,
};

//
// Converts days since 1970-01-01 to a calendar date (Howard Hinnant's civil_from_days algorithm).
//
fn civilFromDays(daysSinceEpoch: i64) CivilDate {
    const shifted_days = daysSinceEpoch + 719468;
    const era = @divFloor(shifted_days, 146097);
    const day_of_era = shifted_days - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_index + 2, 5) + 1;
    const month = if (month_index < 10) month_index + 3 else month_index - 9;
    const year = year_of_era + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

//
// Provides the current time (so tests can substitute a deterministic clock).
//
pub const ITimestampProvider = struct {
    // The timestamp provider implementation.
    ptr: *anyopaque,

    // The functions of the timestamp provider implementation.
    vtable: *const VTable,

    //
    // The functions a timestamp provider implementation provides.
    //
    pub const VTable = struct {
        // Gets the current time in milliseconds since the Unix epoch.
        now: *const fn (ptr: *anyopaque, io: std.Io) i64,

        // Gets the current time as a Date.
        dateNow: *const fn (ptr: *anyopaque, io: std.Io) Date,
    };

    //
    // Gets the current time in milliseconds since the Unix epoch (`Date.now()`).
    //
    pub fn now(self: ITimestampProvider, io: std.Io) i64 {
        return self.vtable.now(self.ptr, io);
    }

    //
    // Gets the current time as a Date (`new Date()`).
    //
    pub fn dateNow(self: ITimestampProvider, io: std.Io) Date {
        return self.vtable.dateNow(self.ptr, io);
    }
};

//
// Provides the real wall-clock time.
//
pub const TimestampProvider = struct {
    // Unused. Present because an ITimestampProvider must point at a value with an address.
    unused: u8 = 0,

    //
    // Gets the ITimestampProvider interface for this provider.
    //
    pub fn timestampProvider(self: *TimestampProvider) ITimestampProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ITimestampProvider functions of this provider.
    //
    const vtable: ITimestampProvider.VTable = .{
        .now = nowErased,
        .dateNow = dateNowErased,
    };

    //
    // Gets the current time in milliseconds since the Unix epoch.
    //
    pub fn now(self: *TimestampProvider, io: std.Io) i64 {
        _ = self;
        return std.Io.Clock.real.now(io).toMilliseconds();
    }

    //
    // Gets the current time as a Date.
    //
    pub fn dateNow(self: *TimestampProvider, io: std.Io) Date {
        return .{ .epochMilliseconds = self.now(io) };
    }

    //
    // Type-erased now for the vtable.
    //
    fn nowErased(ptr: *anyopaque, io: std.Io) i64 {
        const self: *TimestampProvider = @ptrCast(@alignCast(ptr));
        return self.now(io);
    }

    //
    // Type-erased dateNow for the vtable.
    //
    fn dateNowErased(ptr: *anyopaque, io: std.Io) Date {
        const self: *TimestampProvider = @ptrCast(@alignCast(ptr));
        return self.dateNow(io);
    }
};
