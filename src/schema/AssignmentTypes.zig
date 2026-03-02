const std = @import("std");

pub const Language = enum {
    English,
    Spanish,
    Bulgarian,
};

pub const StringOrBool = union(enum) {
    string: []const u8,
    boolean: bool,
};

pub const AssignmentSetting = struct {
    value: StringOrBool = .{ .string = "" },
    isTurnedOn: bool = false,
    share: bool = false,
};

pub const AssignmentSettingsWGSP = struct {
    allowPractice: bool = true,
    allowSubmission: bool = true,
};

pub const Settings = struct {
    listRecommendations: AssignmentSetting = .{},
    aiCheck: AssignmentSetting = .{},
    factCheck: AssignmentSetting = .{},
    relevanceCheck: AssignmentSetting = .{},
    evaluateLogic: AssignmentSetting = .{},
    anonymize: AssignmentSetting = .{},
    extractImages: AssignmentSetting = .{},
    feedbackLength: AssignmentSetting = .{},
    feedbackComplexity: AssignmentSetting = .{},
    citationsCheck: AssignmentSetting = .{},
};

pub const Lock = struct {
    user: ?[]const u8 = null,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
};

pub const AssignmentDocument = struct {
    pk: []const u8,
    sk: []const u8,
    name: []const u8,
};

pub const Assignment = struct {
    pk: []const u8,
    sk: []const u8,
    name: []const u8,
    id: []const u8,
    model: ?[]const u8 = null,
    visibility: []const u8 = "private",
    settingsWGSP: AssignmentSettingsWGSP = .{},
    DATATYPE: []const u8 = "ASSIGNMENT",
    severity: f64 = 0,
    metaData: ?std.json.Value = null,
    description: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    rubric: ?std.json.Value = null,
    OWNER: []const u8,
    sharedWith: [][]const u8 = &.{},
    folder: []const u8,
    lock: ?Lock = null,
    language: Language = .English,
    settings: Settings = .{},
    document: ?AssignmentDocument = null,
};
