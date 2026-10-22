//
// Makes the HEIC picture the tests import, laid out the way an iPhone writes one: a grid of 512 by 512 HEVC tiles, trimmed to the
// picture's size, with an EXIF item describing it.
//
// Nothing on a development machine writes HEIC: FFmpeg has no HEIF muxer and libheif is not installed. FFmpeg (with libx265) does
// encode each tile into an MP4, which holds the tile's coded picture and the HEVC decoder configuration (hvcC) a HEIF tile item
// needs, and exiftool writes the EXIF block. This file takes those pieces out of the MP4s and writes them into a HEIF file's boxes
// (ISO/IEC 23008-12). The picture is FFmpeg's own testsrc2 pattern, so the result is free of anyone's copyright.
//
// Usage: bun scripts/make-heic-test-image.ts --output <file.heic> --width <pixels> --height <pixels> --date <YYYY:MM:DD HH:MM:SS>
//                                            --latitude <degrees> --longitude <degrees> [--orientation <1-8>]
//

import { spawnSync } from "child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

//
// The size of a tile, which is what an iPhone uses.
//
const TILE_SIZE = 512;

//
// What the picture is made from.
//
interface IHeicOptions {
    // The file the HEIC is written to.
    outputPath: string;

    // The width of the picture, in pixels.
    width: number;

    // The height of the picture, in pixels.
    height: number;

    // The EXIF DateTimeOriginal, as EXIF writes it.
    date: string;

    // The EXIF GPS latitude, in degrees, north positive.
    latitude: number;

    // The EXIF GPS longitude, in degrees, east positive.
    longitude: number;

    // The EXIF Orientation, 1 to 8.
    orientation: number;
}

//
// One coded tile, as taken out of the MP4 it was encoded into.
//
interface ITile {
    // The whole hvcC box: its size, its type and the decoder configuration record.
    hvcC: Buffer;

    // The tile's coded picture: its NAL units, each with a four byte length in front.
    data: Buffer;
}

//
// One item's data, as it goes into the mdat box.
//
interface IPayload {
    // The item the data belongs to.
    id: number;

    // The item's data.
    data: Buffer;
}

//
// One box of an ISO base media file.
//
interface IBox {
    // The four character type.
    type: string;

    // Where the box's content starts in the buffer.
    start: number;

    // Where the box ends in the buffer.
    end: number;
}

//
// Reads a required `--name value` argument from the command line, failing loudly when it is absent.
//
function requiredArg(argv: string[], name: string): string {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        throw new Error(`Missing required argument --${name}`);
    }
    return argv[index + 1];
}

//
// Reads an optional `--name value` argument from the command line.
//
function optionalArg(argv: string[], name: string): string | undefined {
    const index = argv.indexOf(`--${name}`);
    if (index === -1) {
        return undefined;
    }
    if (index + 1 >= argv.length) {
        throw new Error(`The argument --${name} has no value`);
    }
    return argv[index + 1];
}

//
// Reads a number argument, failing loudly when it is not a number.
//
function numberArg(text: string, name: string): number {
    const value = Number(text);
    if (!Number.isFinite(value)) {
        throw new Error(`--${name} must be a number, not "${text}"`);
    }
    return value;
}

//
// Runs a program, failing loudly with its output when it fails, and returns what it wrote to its standard output.
//
function run(program: string, args: string[]): Buffer {
    const result = spawnSync(program, args);
    if (result.error) {
        throw new Error(`Could not run ${program}: ${result.error.message}`);
    }
    if (result.status !== 0) {
        throw new Error(`${program} ${args.join(" ")} failed with exit code ${result.status}:\n${result.stderr.toString()}`);
    }
    return result.stdout;
}

//
// Lists the boxes in a range of a buffer.
//
function listBoxes(buffer: Buffer, start: number, end: number): IBox[] {
    const boxes: IBox[] = [];
    let position = start;
    while (position < end) {
        const size = buffer.readUInt32BE(position);
        const type = buffer.toString("latin1", position + 4, position + 8);
        if (size < 8 || position + size > end) {
            throw new Error(`The box "${type}" at ${position} has the size ${size}, which does not fit in its parent`);
        }
        boxes.push({
            type,
            start: position + 8,
            end: position + size,
        });
        position += size;
    }
    return boxes;
}

//
// Finds the one box of a type in a range of a buffer, failing loudly when there is not exactly one.
//
function findBox(buffer: Buffer, start: number, end: number, type: string): IBox {
    const found = listBoxes(buffer, start, end).filter(box => box.type === type);
    if (found.length !== 1) {
        throw new Error(`Expected one "${type}" box, found ${found.length}`);
    }
    return found[0];
}

//
// Takes the decoder configuration and the one coded picture out of an MP4 holding a single HEVC frame.
//
function readTile(mp4: Buffer): ITile {
    const moov = findBox(mp4, 0, mp4.length, "moov");
    const trak = findBox(mp4, moov.start, moov.end, "trak");
    const mdia = findBox(mp4, trak.start, trak.end, "mdia");
    const minf = findBox(mp4, mdia.start, mdia.end, "minf");
    const stbl = findBox(mp4, minf.start, minf.end, "stbl");

    // stsd is a full box with an entry count, and its one entry is the hvc1 sample entry: a visual sample entry (78 bytes after its
    // header) followed by boxes, of which hvcC is one.
    const stsd = findBox(mp4, stbl.start, stbl.end, "stsd");
    const hvc1 = findBox(mp4, stsd.start + 8, stsd.end, "hvc1");
    const hvcC = findBox(mp4, hvc1.start + 78, hvc1.end, "hvcC");

    // A single sample: stsz says how long it is (a full box, then the common sample size, then the count) and stco where it is.
    const stsz = findBox(mp4, stbl.start, stbl.end, "stsz");
    const sampleCount = mp4.readUInt32BE(stsz.start + 8);
    if (sampleCount !== 1) {
        throw new Error(`Expected one sample in the tile's MP4, found ${sampleCount}`);
    }
    const commonSize = mp4.readUInt32BE(stsz.start + 4);
    const sampleSize = commonSize !== 0 ? commonSize : mp4.readUInt32BE(stsz.start + 12);
    const stco = findBox(mp4, stbl.start, stbl.end, "stco");
    const sampleOffset = mp4.readUInt32BE(stco.start + 8);

    return {
        hvcC: Buffer.from(mp4.subarray(hvcC.start - 8, hvcC.end)),
        data: Buffer.from(mp4.subarray(sampleOffset, sampleOffset + sampleSize)),
    };
}

//
// Makes a box from its type and its content.
//
function box(type: string, ...content: Buffer[]): Buffer {
    const body = Buffer.concat(content);
    const header = Buffer.alloc(8);
    header.writeUInt32BE(8 + body.length, 0);
    header.write(type, 4, "latin1");
    return Buffer.concat([header, body]);
}

//
// Makes a full box: a box whose content starts with a version and 24 bits of flags.
//
function fullBox(type: string, version: number, flags: number, ...content: Buffer[]): Buffer {
    const versionAndFlags = Buffer.alloc(4);
    versionAndFlags.writeUInt32BE(((version & 0xff) << 24) | (flags & 0xffffff), 0);
    return box(type, versionAndFlags, ...content);
}

//
// Big-endian unsigned integers of each size the boxes use.
//
function u8(value: number): Buffer {
    const buffer = Buffer.alloc(1);
    buffer.writeUInt8(value, 0);
    return buffer;
}

function u16(value: number): Buffer {
    const buffer = Buffer.alloc(2);
    buffer.writeUInt16BE(value, 0);
    return buffer;
}

function u32(value: number): Buffer {
    const buffer = Buffer.alloc(4);
    buffer.writeUInt32BE(value, 0);
    return buffer;
}

//
// Encodes each tile of the picture with FFmpeg into an MP4 and takes the tile out of it.
//
function encodeTiles(workDir: string, options: IHeicOptions, columns: number, rows: number): ITile[] {
    const tiles: ITile[] = [];
    for (let row = 0; row < rows; row++) {
        for (let column = 0; column < columns; column++) {
            const tilePath = join(workDir, `tile-${row}-${column}.mp4`);
            // The pattern is drawn at the picture's size, padded out to whole tiles (as an encoder does, which is what the grid's
            // trim takes back off), and this tile's square is cut out of it.
            const filter = `pad=${columns * TILE_SIZE}:${rows * TILE_SIZE}:0:0:black,crop=${TILE_SIZE}:${TILE_SIZE}:${column * TILE_SIZE}:${row * TILE_SIZE}`;
            run("ffmpeg", [
                "-v", "error",
                "-f", "lavfi",
                "-i", `testsrc2=size=${options.width}x${options.height}:rate=1`,
                "-frames:v", "1",
                "-vf", filter,
                "-pix_fmt", "yuv420p",
                "-c:v", "libx265",
                "-x265-params", "log-level=error",
                "-tag:v", "hvc1",
                "-y", tilePath,
            ]);
            tiles.push(readTile(readFileSync(tilePath)));
        }
    }
    return tiles;
}

//
// Writes the EXIF block with exiftool and returns it as TIFF data (byte order mark, then the IFDs).
//
function makeExif(workDir: string, options: IHeicOptions): Buffer {
    // exiftool writes EXIF into a JPEG, so a small black JPEG carries it and the block is read back out of that.
    const carrierPath = join(workDir, "exif-carrier.jpg");
    run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=16x16", "-frames:v", "1", "-y", carrierPath]);
    run("exiftool", [
        "-q",
        "-overwrite_original",
        `-DateTimeOriginal=${options.date}`,
        `-CreateDate=${options.date}`,
        `-GPSLatitude=${Math.abs(options.latitude)}`,
        `-GPSLatitudeRef=${options.latitude >= 0 ? "N" : "S"}`,
        `-GPSLongitude=${Math.abs(options.longitude)}`,
        `-GPSLongitudeRef=${options.longitude >= 0 ? "E" : "W"}`,
        `-Orientation#=${options.orientation}`,
        "-Make=Photosphere",
        "-Model=HEIC test picture",
        carrierPath,
    ]);
    const exif = run("exiftool", ["-b", "-EXIF", carrierPath]);
    const byteOrder = exif.toString("latin1", 0, 2);
    if (byteOrder !== "II" && byteOrder !== "MM") {
        throw new Error(`exiftool gave an EXIF block that does not start with a TIFF byte order mark: "${byteOrder}"`);
    }
    return exif;
}

//
// Writes the HEIF file: the ftyp box, the meta box describing the grid, the tiles and the EXIF item, and the mdat box holding them.
//
function writeHeic(options: IHeicOptions, columns: number, rows: number, tiles: ITile[], exif: Buffer): Buffer {
    // Item 1 is the grid, which is the primary picture; items 2 onwards are its tiles, left to right then top to bottom; the last
    // item is the EXIF that describes the grid.
    const gridId = 1;
    const tileIds = tiles.map((tile, index) => 2 + index);
    const exifId = 2 + tiles.length;

    // The grid's own data: version 0, flags 0 (16 bit sizes), the rows and columns less one, and the size the tiles are trimmed to.
    const gridData = Buffer.concat([u8(0), u8(0), u8(rows - 1), u8(columns - 1), u16(options.width), u16(options.height)]);

    // The EXIF item starts with the offset of the TIFF header in what follows, which is straight after the offset.
    const exifData = Buffer.concat([u32(0), exif]);

    // What goes in the mdat box, in order, and the item each part belongs to.
    const payloads: IPayload[] = [
        ...tiles.map((tile, index) => ({
            id: tileIds[index],
            data: tile.data,
        })),
        {
            id: exifId,
            data: exifData,
        },
        {
            id: gridId,
            data: gridData,
        },
    ];

    const infe = (id: number, type: string, hidden: boolean): Buffer => fullBox("infe", 2, hidden ? 1 : 0, u16(id), u16(0), Buffer.from(type, "latin1"), u8(0));
    const iinf = fullBox("iinf", 0, 0, u16(1 + tiles.length + 1),
        infe(gridId, "grid", false),
        ...tileIds.map(id => infe(id, "hvc1", true)),
        infe(exifId, "Exif", true));

    const iref = fullBox("iref", 0, 0,
        box("dimg", u16(gridId), u16(tileIds.length), ...tileIds.map(id => u16(id))),
        box("cdsc", u16(exifId), u16(1), u16(gridId)));

    // The properties: each tile's hvcC (1-based indexes 1 to N), then the tile size (N + 1) and the picture size (N + 2).
    const tileSizeIndex = tiles.length + 1;
    const pictureSizeIndex = tiles.length + 2;
    const ipco = box("ipco",
        ...tiles.map(tile => tile.hvcC),
        fullBox("ispe", 0, 0, u32(TILE_SIZE), u32(TILE_SIZE)),
        fullBox("ispe", 0, 0, u32(options.width), u32(options.height)));
    // An association is one byte: the top bit says the property is essential, the rest is its index.
    const ipma = fullBox("ipma", 0, 0, u32(1 + tiles.length),
        u16(gridId), u8(1), u8(pictureSizeIndex),
        ...tileIds.flatMap((id, index) => [u16(id), u8(2), u8(0x80 | (index + 1)), u8(tileSizeIndex)]));
    const iprp = box("iprp", ipco, ipma);

    const ftyp = box("ftyp", Buffer.from("heic", "latin1"), u32(0), Buffer.from("mif1heic", "latin1"));
    const hdlr = fullBox("hdlr", 0, 0, u32(0), Buffer.from("pict", "latin1"), u32(0), u32(0), u32(0), u8(0));
    const pitm = fullBox("pitm", 0, 0, u16(gridId));

    // iloc gives each item's place in the file as an absolute offset, which is not known until the meta box's size is. Its size does
    // not depend on the offsets it holds, so it is made once with the offsets at zero to measure, then again with them.
    const makeIloc = (mdatDataStart: number): Buffer => {
        let offset = mdatDataStart;
        const entries: Buffer[] = [];
        for (const payload of payloads) {
            // The item, data reference 0 (this file), one extent, its offset and its length.
            entries.push(u16(payload.id), u16(0), u16(1), u32(offset), u32(payload.data.length));
            offset += payload.data.length;
        }
        // Version 0: offset and length are four bytes, there is no base offset, and the four reserved bits are zero.
        return fullBox("iloc", 0, 0, u8(0x44), u8(0x00), u16(payloads.length), ...entries);
    };
    const makeMeta = (mdatDataStart: number): Buffer => fullBox("meta", 0, 0, hdlr, pitm, makeIloc(mdatDataStart), iinf, iref, iprp);

    const measured = makeMeta(0);
    const mdatDataStart = ftyp.length + measured.length + 8;
    const meta = makeMeta(mdatDataStart);
    if (meta.length !== measured.length) {
        throw new Error("The meta box changed size when its offsets were filled in");
    }
    const mdat = box("mdat", ...payloads.map(payload => payload.data));
    return Buffer.concat([ftyp, meta, mdat]);
}

//
// Reads the options from the command line.
//
function readOptions(argv: string[]): IHeicOptions {
    const orientationText = optionalArg(argv, "orientation");
    const options: IHeicOptions = {
        outputPath: requiredArg(argv, "output"),
        width: numberArg(requiredArg(argv, "width"), "width"),
        height: numberArg(requiredArg(argv, "height"), "height"),
        date: requiredArg(argv, "date"),
        latitude: numberArg(requiredArg(argv, "latitude"), "latitude"),
        longitude: numberArg(requiredArg(argv, "longitude"), "longitude"),
        orientation: orientationText === undefined ? 1 : numberArg(orientationText, "orientation"),
    };
    if (options.width < 1 || options.width > 65535 || options.height < 1 || options.height > 65535) {
        throw new Error("--width and --height must be between 1 and 65535, which is what a grid with 16 bit sizes can hold");
    }
    if (!/^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$/.test(options.date)) {
        throw new Error(`--date must be written as EXIF writes it, YYYY:MM:DD HH:MM:SS, not "${options.date}"`);
    }
    if (!Number.isInteger(options.orientation) || options.orientation < 1 || options.orientation > 8) {
        throw new Error(`--orientation must be a whole number from 1 to 8, not "${options.orientation}"`);
    }
    return options;
}

//
// Makes the picture.
//
function main(): void {
    const options = readOptions(process.argv.slice(2));
    const columns = Math.ceil(options.width / TILE_SIZE);
    const rows = Math.ceil(options.height / TILE_SIZE);
    // The MP4s and the EXIF carrier go in a directory of their own under the repository's tmp directory, made fresh for each run.
    mkdirSync("tmp", { recursive: true });
    const workDir = mkdtempSync(join("tmp", "make-heic-"));
    const tiles = encodeTiles(workDir, options, columns, rows);
    const exif = makeExif(workDir, options);
    writeFileSync(options.outputPath, writeHeic(options, columns, rows, tiles, exif));
    console.log(`Wrote ${options.outputPath}: ${options.width}x${options.height}, ${columns}x${rows} tiles of ${TILE_SIZE}.`);
}

main();
