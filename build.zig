const std = @import("std");

pub const notcurses_version = std.builtin.Version{
    .major = 3,
    .minor = 0,
    .patch = 8,
};

pub const version_header_template = @embedFile("tools/version.h.zig.in");
pub const build_definition_template = @embedFile("tools/builddef.h.zig.in");
pub const Template = union(enum) {
    version_header: std.builtin.Version,
    build_definition: BuildDefinition,

    fn file_name(template: Template) []const u8 {
        return switch (template) {
            .version_header => "version.h",
            .build_definition => "builddef.h",
        };
    }

    fn print(template: Template, builder: *std.build.Builder, writer: anytype) !void {
        switch (template) {
            .version_header => |version| return writer.print(version_header_template, .{
                version.major,
                version.minor,
                version.patch,
                0, // tweak
                version.major,
                version.minor,
                version.patch,
                0, // tweak
            }),
            .build_definition => |build_definition| return build_definition.print(builder, writer),
        }
    }
};

pub const CmakeGeneratedFileStep = struct {
    const FileWriter = std.fs.File.Writer;

    step: std.build.Step,
    builder: *std.build.Builder,
    parent_step: *std.build.LibExeObjStep,
    templates: [2]Template,

    pub fn create(builder: *std.build.Builder, parent_step: *std.build.LibExeObjStep, templates: [2]Template) !*@This() {
        var self = try builder.allocator.create(@This());
        self.* = @This(){
            .builder = builder,
            .parent_step = parent_step,
            .step = std.build.Step.init(.custom, @typeName(@This()), builder.allocator, make),
            .templates = templates,
        };
        return self;
    }

    pub fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(@This(), "step", step);

        const generated_folder_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{ self.builder.cache_root, "generated" });
        defer self.builder.allocator.free(generated_folder_path);

        std.log.info("Creating generated file folder at \"{s}\"", .{generated_folder_path});
        std.fs.cwd().makeDir(generated_folder_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        for (self.templates) |*template| {
            const file_path = try std.fs.path.join(self.builder.allocator, &[_][]const u8{ generated_folder_path, template.file_name() });
            defer self.builder.allocator.free(file_path);

            std.log.info("Creating {s} at \"{s}\"", .{ template.file_name(), file_path });

            var file_handle = try std.fs.cwd().createFile(file_path, .{});
            defer file_handle.close();
            var file_writer = file_handle.writer();

            template.print(self.builder, file_writer) catch |err| {
                std.log.err("Failed to produce \"{s}\": {}", .{ template.file_name(), err });
            };
        }

        self.parent_step.addIncludeDir(generated_folder_path);
    }
};

pub const MultimediaEngine = enum {
    ffmpeg,
    oiio,
};

pub const BuildDefinition = struct {
    dfsg_build: bool,
    use_asan: bool,
    use_coverage: bool,
    build_cpp: bool,
    use_deflate: bool,
    use_doxygen: bool,
    use_gpm: bool,
    use_pandoc: bool,
    build_executables: bool,
    build_ffi_library: bool,
    use_poc: bool,
    use_qrcodegen: bool,
    use_static: bool,
    maybe_use_multimedia: ?MultimediaEngine,

    fn printOption(name: []const u8, value: bool, writer: anytype) !void {
        return if (value)
            writer.print("#define {s}\n", .{name})
        else
            writer.print("/* #undef {s} */\n", .{name});
    }

    fn print(build_definition: BuildDefinition, builder: *std.build.Builder, writer: anytype) !void {
        try BuildDefinition.printOption("DFSG_BUILD", build_definition.dfsg_build, writer);
        try BuildDefinition.printOption("USE_ASAN", build_definition.use_asan, writer);
        try BuildDefinition.printOption("USE_DEFLATE", build_definition.use_deflate, writer);
        try BuildDefinition.printOption("USE_GPM", build_definition.use_gpm, writer);
        try BuildDefinition.printOption("USE_QRCODEGEN", build_definition.use_qrcodegen, writer);
        try BuildDefinition.printOption("USE_OIIO", build_definition.maybe_use_multimedia != null and build_definition.maybe_use_multimedia.? == .oiio, writer);
        try BuildDefinition.printOption("USE_GPM", build_definition.use_gpm, writer);

        if (build_definition.maybe_use_multimedia != null) {
            try writer.writeAll("#define NOTCURSES_USE_MULTIMEDIA\n");
        }

        try writer.print("#define NOTCURSES_SHARE \"{s}\"", .{builder.install_prefix});
    }

    fn addOptionsToBuilder(b: *std.build.Builder) @This() {
        return @This(){
            .dfsg_build = b.option(bool, "dfsg_build", "DFSG build (no non-free media/code)") orelse false,
            .use_asan = b.option(bool, "use_asan", "Build with AddressSanitizer") orelse false,
            .use_coverage = b.option(bool, "use_coverage", "Assess code coverage with llvm-cov/lcov") orelse false,
            .build_cpp = b.option(bool, "use_cxx", "Build C++ code") orelse true,
            // TODO(haze): doctest
            .use_deflate = b.option(bool, "use_deflate", "Use libdeflate instead of libz") orelse true,
            .use_doxygen = b.option(bool, "use_doxygen", "Build HTML cross reference with doxygen") orelse false,
            .use_gpm = b.option(bool, "use_gpm", "Enable libgpm console mouse support") orelse false,
            .use_pandoc = b.option(bool, "use_pandoc", "Build man pages and HTML reference with pandoc") orelse true,
            .build_executables = b.option(bool, "build_executables", "Build executables") orelse true,
            .build_ffi_library = b.option(bool, "build_ffi_library", "Build ffi library (containing all symbols which are static inline)") orelse true,
            .use_poc = b.option(bool, "use_poc", "Build small, uninstalled proof-of-concept binaries") orelse true,
            .use_qrcodegen = b.option(bool, "use_qrcodegen", "Enable libqrcodegen QR code support") orelse false,
            .use_static = b.option(bool, "use_static", "Build static libraries (in addition to shared)") orelse true,
            // TODO(haze): change default to ffmpeg
            .maybe_use_multimedia = b.option(MultimediaEngine, "use_multimedia", "Multimedia engine, one of 'ffmpeg', 'oiio', or 'none'"),
        };
    }
};

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();

    const build_definition = try addNotCursesOptions(b);
    var notcurses_core = if (build_definition.use_static)
        b.addStaticLibrary("notcurses-core-static", null)
    else
        b.addSharedLibrary("notcurses-core", null, .{
            .versioned = notcurses_version,
        });

    try addNotCursesSymbolsToStep("", build_definition, b, notcurses_core);
    notcurses_core.setBuildMode(mode);
    notcurses_core.linkLibC();
    notcurses_core.install();

    // if you see this no you didnt
    // notcurses_core.addIncludePath("/nix/store/n21y30l69psnvpwjr0la3kmlnrvc6qz7-ncurses-6.3-dev/include");
    // notcurses_core.addIncludePath("/nix/store/9zc54l2sw1vbk4b22418yc4fq7b8mpy9-libunistring-0.9.10-dev/include");
    // notcurses_core.addIncludePath("/nix/store/8n53jsvbnqxrasgwd3c2xjygai9v4byl-libdeflate-1.8/include");
}

pub fn addNotCursesOptions(builder: *std.build.Builder) !BuildDefinition {
    var build_definition = BuildDefinition.addOptionsToBuilder(builder);

    if (build_definition.maybe_use_multimedia) |use_multimedia| {
        switch (use_multimedia) {
            .oiio => {
                if (!build_definition.build_cpp) {
                    return error.NeedCPP;
                }
            },
            else => {},
        }
    }

    if (!build_definition.build_executables and build_definition.use_poc) {
        std.log.warn("Disabling USE_POC since BUILD_EXECUTABLES=OFF", .{});
        build_definition.use_poc = false;
    }

    std.log.info("Requested multimedia engine: {?}", .{build_definition.maybe_use_multimedia});

    return build_definition;
}

pub fn addNotCursesSymbolsToStep(comptime root: []const u8, build_definition: BuildDefinition, builder: *std.build.Builder, step: *std.build.LibExeObjStep) !void {
    const version_header_step = try CmakeGeneratedFileStep.create(builder, step, [2]Template{
        .{ .version_header = notcurses_version },
        .{ .build_definition = build_definition },
    });
    step.step.dependOn(&version_header_step.step);
    addNotCursesSources(root, step, build_definition.use_asan);
    addNotCursesCompatSources(root, step, build_definition.use_asan);
}

pub fn linkNotCursesLibraries(step: *std.build.LibExeObjStep) void {
    step.linkSystemLibrary("libdeflate");
    step.linkSystemLibrary("terminfo");
    step.linkSystemLibrary("libm");
    step.linkSystemLibrary("gpm");
    step.linkSystemLibrary("unistring");
}

pub fn addNotCursesSources(comptime root: []const u8, step: *std.build.LibExeObjStep, use_asan: bool) void {
    step.addCSourceFiles(&[_][]const u8{
        root ++ "src/lib/automaton.c",
        root ++ "src/lib/banner.c",
        root ++ "src/lib/blit.c",
        root ++ "src/lib/debug.c",
        root ++ "src/lib/direct.c",
        root ++ "src/lib/egcpool.h",
        root ++ "src/lib/fade.c",
        root ++ "src/lib/fd.c",
        root ++ "src/lib/fill.c",
        root ++ "src/lib/gpm.c",
        root ++ "src/lib/in.c",
        root ++ "src/lib/kitty.c",
        root ++ "src/lib/layout.c",
        root ++ "src/lib/linux.c",
        root ++ "src/lib/menu.c",
        root ++ "src/lib/metric.c",
        root ++ "src/lib/mice.c",
        root ++ "src/lib/notcurses.c",
        root ++ "src/lib/plot.c",
        root ++ "src/lib/progbar.c",
        root ++ "src/lib/reader.c",
        root ++ "src/lib/reel.c",
        root ++ "src/lib/render.c",
        root ++ "src/lib/selector.c",
        root ++ "src/lib/sixel.c",
        root ++ "src/lib/sprite.c",
        root ++ "src/lib/stats.c",
        root ++ "src/lib/tabbed.c",
        root ++ "src/lib/termdesc.c",
        root ++ "src/lib/termdesc.h",
        root ++ "src/lib/tree.c",
        root ++ "src/lib/unixsig.c",
        root ++ "src/lib/util.c",
        root ++ "src/lib/visual.c",
        root ++ "src/lib/windows.c",
    }, globalCompilerFlags(use_asan));
    step.addIncludePath(root ++ "src");
    step.addIncludePath(root ++ "include");
}

pub fn addNotCursesCompatSources(
    comptime root: []const u8,
    step: *std.build.LibExeObjStep,
    use_asan: bool,
) void {
    step.addCSourceFiles(&[_][]const u8{
        root ++ "src/compat/compat.c",
    }, globalCompilerFlags(use_asan));
    step.addIncludePath(root ++ "src");
    step.addIncludePath(root ++ "include");
}

pub fn globalCompilerFlags(use_asan: bool) []const []const u8 {
    return if (use_asan)
        &[_][]const u8{
            "-Wall",
            "-Wextra",
            "-W",
            "-Wshadow",
            "-Wvla",
            "-Wstrict-aliasing=2",
            "-Wformat",
            "-Werror=format-security",
            "-fno-signed-zeros",
            "-fno-trapping-math",
            "-fassociative-math",
            "-fno-math-errno",
            "-freciprocal-math",
            "-funsafe-math-optimizations",
            "-fexceptions",
            "-fstrict-aliasing",
            "-fsanitize=address",
        }
    else
        &[_][]const u8{
            "-Wall",
            "-Wextra",
            "-W",
            "-Wshadow",
            "-Wvla",
            "-Wstrict-aliasing=2",
            "-Wformat",
            "-Werror=format-security",
            "-fno-signed-zeros",
            "-fno-trapping-math",
            "-fassociative-math",
            "-fno-math-errno",
            "-freciprocal-math",
            "-funsafe-math-optimizations",
            "-fexceptions",
            "-fstrict-aliasing",
        };
}
