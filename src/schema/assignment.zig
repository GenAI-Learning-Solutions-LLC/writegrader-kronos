const std = @import("std");

pub const CriteriaRule = struct {
    points: f64 = 0,
    description: []const u8 = "",
};

pub const SubCriterionItem = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    range: [2]f64 = .{ 0, 0 },
};

pub const Criterion = struct {
    name: []const u8 = "",
    rules: ?[]CriteriaRule = null,
    subCriterion: []SubCriterionItem = &.{},
    aiPrompt: []const u8 = "",
    studentPrompt: []const u8 = "",
    points: f64 = 0,
    isNegative: bool = false,
    teacherOnly: bool = false,
    round: bool = true,
    feedbackOnly: bool = false,
    isManuallyGraded: bool = false,
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
};

pub const Rubric = struct {
    pk: []const u8 = "",
    sk: []const u8 = "",
    name: []const u8 = "",
    lock: bool = false,
    rubricType: []const u8 = "RUBRIC",
    DATATYPE: []const u8 = "RUBRIC",
    description: []const u8 = "",
    OWNER: []const u8 = "",
    folder: []const u8 = "",
    criteria: []Criterion = &.{},
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
};

pub const Language = enum {
    English,
    Spanish,
    Bulgarian,
};

pub const AssignmentSetting = struct {
    value: std.json.Value = .{ .string = "" },
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
    rubric: ?Rubric = null,
    OWNER: []const u8,
    sharedWith: [][]const u8 = &.{},
    folder: []const u8,
    lock: ?Lock = null,
    language: Language = .English,
    settings: Settings = .{},
    document: ?AssignmentDocument = null,
};
