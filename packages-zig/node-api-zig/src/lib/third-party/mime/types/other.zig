//
// Port of mime 4.1.0 types/other.ts: the other MIME types and their extensions, in the order the file lists them.
//
// mime (c) 2023 Robert Kieffer, MIT license.
//

const TypeMapEntry = @import("../Mime.zig").TypeMapEntry;

//
// The types (TypeScript: the `types` object, as a list of its entries in order).
//
pub const types = [_]TypeMapEntry{
    .{
        .type = "application/prs.cww",
        .extensions = &.{ "cww" },
    },
    .{
        .type = "application/prs.xsf+xml",
        .extensions = &.{ "xsf" },
    },
    .{
        .type = "application/vnd.1000minds.decision-model+xml",
        .extensions = &.{ "1km" },
    },
    .{
        .type = "application/vnd.3gpp.pic-bw-large",
        .extensions = &.{ "plb" },
    },
    .{
        .type = "application/vnd.3gpp.pic-bw-small",
        .extensions = &.{ "psb" },
    },
    .{
        .type = "application/vnd.3gpp.pic-bw-var",
        .extensions = &.{ "pvb" },
    },
    .{
        .type = "application/vnd.3gpp2.tcap",
        .extensions = &.{ "tcap" },
    },
    .{
        .type = "application/vnd.3m.post-it-notes",
        .extensions = &.{ "pwn" },
    },
    .{
        .type = "application/vnd.accpac.simply.aso",
        .extensions = &.{ "aso" },
    },
    .{
        .type = "application/vnd.accpac.simply.imp",
        .extensions = &.{ "imp" },
    },
    .{
        .type = "application/vnd.acucobol",
        .extensions = &.{ "acu" },
    },
    .{
        .type = "application/vnd.acucorp",
        .extensions = &.{ "atc", "acutc" },
    },
    .{
        .type = "application/vnd.adobe.air-application-installer-package+zip",
        .extensions = &.{ "air" },
    },
    .{
        .type = "application/vnd.adobe.formscentral.fcdt",
        .extensions = &.{ "fcdt" },
    },
    .{
        .type = "application/vnd.adobe.fxp",
        .extensions = &.{ "fxp", "fxpl" },
    },
    .{
        .type = "application/vnd.adobe.xdp+xml",
        .extensions = &.{ "xdp" },
    },
    .{
        .type = "application/vnd.adobe.xfdf",
        .extensions = &.{ "*xfdf" },
    },
    .{
        .type = "application/vnd.age",
        .extensions = &.{ "age" },
    },
    .{
        .type = "application/vnd.ahead.space",
        .extensions = &.{ "ahead" },
    },
    .{
        .type = "application/vnd.airzip.filesecure.azf",
        .extensions = &.{ "azf" },
    },
    .{
        .type = "application/vnd.airzip.filesecure.azs",
        .extensions = &.{ "azs" },
    },
    .{
        .type = "application/vnd.amazon.ebook",
        .extensions = &.{ "azw" },
    },
    .{
        .type = "application/vnd.americandynamics.acc",
        .extensions = &.{ "acc" },
    },
    .{
        .type = "application/vnd.amiga.ami",
        .extensions = &.{ "ami" },
    },
    .{
        .type = "application/vnd.android.package-archive",
        .extensions = &.{ "apk" },
    },
    .{
        .type = "application/vnd.anser-web-certificate-issue-initiation",
        .extensions = &.{ "cii" },
    },
    .{
        .type = "application/vnd.anser-web-funds-transfer-initiation",
        .extensions = &.{ "fti" },
    },
    .{
        .type = "application/vnd.antix.game-component",
        .extensions = &.{ "atx" },
    },
    .{
        .type = "application/vnd.apple.installer+xml",
        .extensions = &.{ "mpkg" },
    },
    .{
        .type = "application/vnd.apple.keynote",
        .extensions = &.{ "key" },
    },
    .{
        .type = "application/vnd.apple.mpegurl",
        .extensions = &.{ "m3u8" },
    },
    .{
        .type = "application/vnd.apple.numbers",
        .extensions = &.{ "numbers" },
    },
    .{
        .type = "application/vnd.apple.pages",
        .extensions = &.{ "pages" },
    },
    .{
        .type = "application/vnd.apple.pkpass",
        .extensions = &.{ "pkpass" },
    },
    .{
        .type = "application/vnd.aristanetworks.swi",
        .extensions = &.{ "swi" },
    },
    .{
        .type = "application/vnd.astraea-software.iota",
        .extensions = &.{ "iota" },
    },
    .{
        .type = "application/vnd.audiograph",
        .extensions = &.{ "aep" },
    },
    .{
        .type = "application/vnd.autodesk.fbx",
        .extensions = &.{ "fbx" },
    },
    .{
        .type = "application/vnd.balsamiq.bmml+xml",
        .extensions = &.{ "bmml" },
    },
    .{
        .type = "application/vnd.blueice.multipass",
        .extensions = &.{ "mpm" },
    },
    .{
        .type = "application/vnd.bmi",
        .extensions = &.{ "bmi" },
    },
    .{
        .type = "application/vnd.businessobjects",
        .extensions = &.{ "rep" },
    },
    .{
        .type = "application/vnd.chemdraw+xml",
        .extensions = &.{ "cdxml" },
    },
    .{
        .type = "application/vnd.chipnuts.karaoke-mmd",
        .extensions = &.{ "mmd" },
    },
    .{
        .type = "application/vnd.cinderella",
        .extensions = &.{ "cdy" },
    },
    .{
        .type = "application/vnd.citationstyles.style+xml",
        .extensions = &.{ "csl" },
    },
    .{
        .type = "application/vnd.claymore",
        .extensions = &.{ "cla" },
    },
    .{
        .type = "application/vnd.cloanto.rp9",
        .extensions = &.{ "rp9" },
    },
    .{
        .type = "application/vnd.clonk.c4group",
        .extensions = &.{ "c4g", "c4d", "c4f", "c4p", "c4u" },
    },
    .{
        .type = "application/vnd.cluetrust.cartomobile-config",
        .extensions = &.{ "c11amc" },
    },
    .{
        .type = "application/vnd.cluetrust.cartomobile-config-pkg",
        .extensions = &.{ "c11amz" },
    },
    .{
        .type = "application/vnd.commonspace",
        .extensions = &.{ "csp" },
    },
    .{
        .type = "application/vnd.contact.cmsg",
        .extensions = &.{ "cdbcmsg" },
    },
    .{
        .type = "application/vnd.cosmocaller",
        .extensions = &.{ "cmc" },
    },
    .{
        .type = "application/vnd.crick.clicker",
        .extensions = &.{ "clkx" },
    },
    .{
        .type = "application/vnd.crick.clicker.keyboard",
        .extensions = &.{ "clkk" },
    },
    .{
        .type = "application/vnd.crick.clicker.palette",
        .extensions = &.{ "clkp" },
    },
    .{
        .type = "application/vnd.crick.clicker.template",
        .extensions = &.{ "clkt" },
    },
    .{
        .type = "application/vnd.crick.clicker.wordbank",
        .extensions = &.{ "clkw" },
    },
    .{
        .type = "application/vnd.criticaltools.wbs+xml",
        .extensions = &.{ "wbs" },
    },
    .{
        .type = "application/vnd.ctc-posml",
        .extensions = &.{ "pml" },
    },
    .{
        .type = "application/vnd.cups-ppd",
        .extensions = &.{ "ppd" },
    },
    .{
        .type = "application/vnd.curl.car",
        .extensions = &.{ "car" },
    },
    .{
        .type = "application/vnd.curl.pcurl",
        .extensions = &.{ "pcurl" },
    },
    .{
        .type = "application/vnd.dart",
        .extensions = &.{ "dart" },
    },
    .{
        .type = "application/vnd.data-vision.rdz",
        .extensions = &.{ "rdz" },
    },
    .{
        .type = "application/vnd.dbf",
        .extensions = &.{ "dbf" },
    },
    .{
        .type = "application/vnd.dcmp+xml",
        .extensions = &.{ "dcmp" },
    },
    .{
        .type = "application/vnd.dece.data",
        .extensions = &.{ "uvf", "uvvf", "uvd", "uvvd" },
    },
    .{
        .type = "application/vnd.dece.ttml+xml",
        .extensions = &.{ "uvt", "uvvt" },
    },
    .{
        .type = "application/vnd.dece.unspecified",
        .extensions = &.{ "uvx", "uvvx" },
    },
    .{
        .type = "application/vnd.dece.zip",
        .extensions = &.{ "uvz", "uvvz" },
    },
    .{
        .type = "application/vnd.denovo.fcselayout-link",
        .extensions = &.{ "fe_launch" },
    },
    .{
        .type = "application/vnd.dna",
        .extensions = &.{ "dna" },
    },
    .{
        .type = "application/vnd.dolby.mlp",
        .extensions = &.{ "mlp" },
    },
    .{
        .type = "application/vnd.dpgraph",
        .extensions = &.{ "dpg" },
    },
    .{
        .type = "application/vnd.dreamfactory",
        .extensions = &.{ "dfac" },
    },
    .{
        .type = "application/vnd.ds-keypoint",
        .extensions = &.{ "kpxx" },
    },
    .{
        .type = "application/vnd.dvb.ait",
        .extensions = &.{ "ait" },
    },
    .{
        .type = "application/vnd.dvb.service",
        .extensions = &.{ "svc" },
    },
    .{
        .type = "application/vnd.dynageo",
        .extensions = &.{ "geo" },
    },
    .{
        .type = "application/vnd.ecowin.chart",
        .extensions = &.{ "mag" },
    },
    .{
        .type = "application/vnd.enliven",
        .extensions = &.{ "nml" },
    },
    .{
        .type = "application/vnd.epson.esf",
        .extensions = &.{ "esf" },
    },
    .{
        .type = "application/vnd.epson.msf",
        .extensions = &.{ "msf" },
    },
    .{
        .type = "application/vnd.epson.quickanime",
        .extensions = &.{ "qam" },
    },
    .{
        .type = "application/vnd.epson.salt",
        .extensions = &.{ "slt" },
    },
    .{
        .type = "application/vnd.epson.ssf",
        .extensions = &.{ "ssf" },
    },
    .{
        .type = "application/vnd.eszigno3+xml",
        .extensions = &.{ "es3", "et3" },
    },
    .{
        .type = "application/vnd.ezpix-album",
        .extensions = &.{ "ez2" },
    },
    .{
        .type = "application/vnd.ezpix-package",
        .extensions = &.{ "ez3" },
    },
    .{
        .type = "application/vnd.fdf",
        .extensions = &.{ "*fdf" },
    },
    .{
        .type = "application/vnd.fdsn.mseed",
        .extensions = &.{ "mseed" },
    },
    .{
        .type = "application/vnd.fdsn.seed",
        .extensions = &.{ "seed", "dataless" },
    },
    .{
        .type = "application/vnd.flographit",
        .extensions = &.{ "gph" },
    },
    .{
        .type = "application/vnd.fluxtime.clip",
        .extensions = &.{ "ftc" },
    },
    .{
        .type = "application/vnd.framemaker",
        .extensions = &.{ "fm", "frame", "maker", "book" },
    },
    .{
        .type = "application/vnd.frogans.fnc",
        .extensions = &.{ "fnc" },
    },
    .{
        .type = "application/vnd.frogans.ltf",
        .extensions = &.{ "ltf" },
    },
    .{
        .type = "application/vnd.fsc.weblaunch",
        .extensions = &.{ "fsc" },
    },
    .{
        .type = "application/vnd.fujitsu.oasys",
        .extensions = &.{ "oas" },
    },
    .{
        .type = "application/vnd.fujitsu.oasys2",
        .extensions = &.{ "oa2" },
    },
    .{
        .type = "application/vnd.fujitsu.oasys3",
        .extensions = &.{ "oa3" },
    },
    .{
        .type = "application/vnd.fujitsu.oasysgp",
        .extensions = &.{ "fg5" },
    },
    .{
        .type = "application/vnd.fujitsu.oasysprs",
        .extensions = &.{ "bh2" },
    },
    .{
        .type = "application/vnd.fujixerox.ddd",
        .extensions = &.{ "ddd" },
    },
    .{
        .type = "application/vnd.fujixerox.docuworks",
        .extensions = &.{ "xdw" },
    },
    .{
        .type = "application/vnd.fujixerox.docuworks.binder",
        .extensions = &.{ "xbd" },
    },
    .{
        .type = "application/vnd.fuzzysheet",
        .extensions = &.{ "fzs" },
    },
    .{
        .type = "application/vnd.genomatix.tuxedo",
        .extensions = &.{ "txd" },
    },
    .{
        .type = "application/vnd.geogebra.file",
        .extensions = &.{ "ggb" },
    },
    .{
        .type = "application/vnd.geogebra.slides",
        .extensions = &.{ "ggs" },
    },
    .{
        .type = "application/vnd.geogebra.tool",
        .extensions = &.{ "ggt" },
    },
    .{
        .type = "application/vnd.geometry-explorer",
        .extensions = &.{ "gex", "gre" },
    },
    .{
        .type = "application/vnd.geonext",
        .extensions = &.{ "gxt" },
    },
    .{
        .type = "application/vnd.geoplan",
        .extensions = &.{ "g2w" },
    },
    .{
        .type = "application/vnd.geospace",
        .extensions = &.{ "g3w" },
    },
    .{
        .type = "application/vnd.gmx",
        .extensions = &.{ "gmx" },
    },
    .{
        .type = "application/vnd.google-apps.document",
        .extensions = &.{ "gdoc" },
    },
    .{
        .type = "application/vnd.google-apps.drawing",
        .extensions = &.{ "gdraw" },
    },
    .{
        .type = "application/vnd.google-apps.form",
        .extensions = &.{ "gform" },
    },
    .{
        .type = "application/vnd.google-apps.jam",
        .extensions = &.{ "gjam" },
    },
    .{
        .type = "application/vnd.google-apps.map",
        .extensions = &.{ "gmap" },
    },
    .{
        .type = "application/vnd.google-apps.presentation",
        .extensions = &.{ "gslides" },
    },
    .{
        .type = "application/vnd.google-apps.script",
        .extensions = &.{ "gscript" },
    },
    .{
        .type = "application/vnd.google-apps.site",
        .extensions = &.{ "gsite" },
    },
    .{
        .type = "application/vnd.google-apps.spreadsheet",
        .extensions = &.{ "gsheet" },
    },
    .{
        .type = "application/vnd.google-earth.kml+xml",
        .extensions = &.{ "kml" },
    },
    .{
        .type = "application/vnd.google-earth.kmz",
        .extensions = &.{ "kmz" },
    },
    .{
        .type = "application/vnd.gov.sk.xmldatacontainer+xml",
        .extensions = &.{ "xdcf" },
    },
    .{
        .type = "application/vnd.grafeq",
        .extensions = &.{ "gqf", "gqs" },
    },
    .{
        .type = "application/vnd.groove-account",
        .extensions = &.{ "gac" },
    },
    .{
        .type = "application/vnd.groove-help",
        .extensions = &.{ "ghf" },
    },
    .{
        .type = "application/vnd.groove-identity-message",
        .extensions = &.{ "gim" },
    },
    .{
        .type = "application/vnd.groove-injector",
        .extensions = &.{ "grv" },
    },
    .{
        .type = "application/vnd.groove-tool-message",
        .extensions = &.{ "gtm" },
    },
    .{
        .type = "application/vnd.groove-tool-template",
        .extensions = &.{ "tpl" },
    },
    .{
        .type = "application/vnd.groove-vcard",
        .extensions = &.{ "vcg" },
    },
    .{
        .type = "application/vnd.hal+xml",
        .extensions = &.{ "hal" },
    },
    .{
        .type = "application/vnd.handheld-entertainment+xml",
        .extensions = &.{ "zmm" },
    },
    .{
        .type = "application/vnd.hbci",
        .extensions = &.{ "hbci" },
    },
    .{
        .type = "application/vnd.hhe.lesson-player",
        .extensions = &.{ "les" },
    },
    .{
        .type = "application/vnd.hp-hpgl",
        .extensions = &.{ "hpgl" },
    },
    .{
        .type = "application/vnd.hp-hpid",
        .extensions = &.{ "hpid" },
    },
    .{
        .type = "application/vnd.hp-hps",
        .extensions = &.{ "hps" },
    },
    .{
        .type = "application/vnd.hp-jlyt",
        .extensions = &.{ "jlt" },
    },
    .{
        .type = "application/vnd.hp-pcl",
        .extensions = &.{ "pcl" },
    },
    .{
        .type = "application/vnd.hp-pclxl",
        .extensions = &.{ "pclxl" },
    },
    .{
        .type = "application/vnd.hydrostatix.sof-data",
        .extensions = &.{ "sfd-hdstx" },
    },
    .{
        .type = "application/vnd.ibm.minipay",
        .extensions = &.{ "mpy" },
    },
    .{
        .type = "application/vnd.ibm.modcap",
        .extensions = &.{ "afp", "listafp", "list3820" },
    },
    .{
        .type = "application/vnd.ibm.rights-management",
        .extensions = &.{ "irm" },
    },
    .{
        .type = "application/vnd.ibm.secure-container",
        .extensions = &.{ "sc" },
    },
    .{
        .type = "application/vnd.iccprofile",
        .extensions = &.{ "icc", "icm" },
    },
    .{
        .type = "application/vnd.igloader",
        .extensions = &.{ "igl" },
    },
    .{
        .type = "application/vnd.immervision-ivp",
        .extensions = &.{ "ivp" },
    },
    .{
        .type = "application/vnd.immervision-ivu",
        .extensions = &.{ "ivu" },
    },
    .{
        .type = "application/vnd.insors.igm",
        .extensions = &.{ "igm" },
    },
    .{
        .type = "application/vnd.intercon.formnet",
        .extensions = &.{ "xpw", "xpx" },
    },
    .{
        .type = "application/vnd.intergeo",
        .extensions = &.{ "i2g" },
    },
    .{
        .type = "application/vnd.intu.qbo",
        .extensions = &.{ "qbo" },
    },
    .{
        .type = "application/vnd.intu.qfx",
        .extensions = &.{ "qfx" },
    },
    .{
        .type = "application/vnd.ipunplugged.rcprofile",
        .extensions = &.{ "rcprofile" },
    },
    .{
        .type = "application/vnd.irepository.package+xml",
        .extensions = &.{ "irp" },
    },
    .{
        .type = "application/vnd.is-xpr",
        .extensions = &.{ "xpr" },
    },
    .{
        .type = "application/vnd.isac.fcs",
        .extensions = &.{ "fcs" },
    },
    .{
        .type = "application/vnd.jam",
        .extensions = &.{ "jam" },
    },
    .{
        .type = "application/vnd.jcp.javame.midlet-rms",
        .extensions = &.{ "rms" },
    },
    .{
        .type = "application/vnd.jisp",
        .extensions = &.{ "jisp" },
    },
    .{
        .type = "application/vnd.joost.joda-archive",
        .extensions = &.{ "joda" },
    },
    .{
        .type = "application/vnd.kahootz",
        .extensions = &.{ "ktz", "ktr" },
    },
    .{
        .type = "application/vnd.kde.karbon",
        .extensions = &.{ "karbon" },
    },
    .{
        .type = "application/vnd.kde.kchart",
        .extensions = &.{ "chrt" },
    },
    .{
        .type = "application/vnd.kde.kformula",
        .extensions = &.{ "kfo" },
    },
    .{
        .type = "application/vnd.kde.kivio",
        .extensions = &.{ "flw" },
    },
    .{
        .type = "application/vnd.kde.kontour",
        .extensions = &.{ "kon" },
    },
    .{
        .type = "application/vnd.kde.kpresenter",
        .extensions = &.{ "kpr", "kpt" },
    },
    .{
        .type = "application/vnd.kde.kspread",
        .extensions = &.{ "ksp" },
    },
    .{
        .type = "application/vnd.kde.kword",
        .extensions = &.{ "kwd", "kwt" },
    },
    .{
        .type = "application/vnd.kenameaapp",
        .extensions = &.{ "htke" },
    },
    .{
        .type = "application/vnd.kidspiration",
        .extensions = &.{ "kia" },
    },
    .{
        .type = "application/vnd.kinar",
        .extensions = &.{ "kne", "knp" },
    },
    .{
        .type = "application/vnd.koan",
        .extensions = &.{ "skp", "skd", "skt", "skm" },
    },
    .{
        .type = "application/vnd.kodak-descriptor",
        .extensions = &.{ "sse" },
    },
    .{
        .type = "application/vnd.las.las+xml",
        .extensions = &.{ "lasxml" },
    },
    .{
        .type = "application/vnd.llamagraphics.life-balance.desktop",
        .extensions = &.{ "lbd" },
    },
    .{
        .type = "application/vnd.llamagraphics.life-balance.exchange+xml",
        .extensions = &.{ "lbe" },
    },
    .{
        .type = "application/vnd.lotus-1-2-3",
        .extensions = &.{ "123" },
    },
    .{
        .type = "application/vnd.lotus-approach",
        .extensions = &.{ "apr" },
    },
    .{
        .type = "application/vnd.lotus-freelance",
        .extensions = &.{ "pre" },
    },
    .{
        .type = "application/vnd.lotus-notes",
        .extensions = &.{ "nsf" },
    },
    .{
        .type = "application/vnd.lotus-organizer",
        .extensions = &.{ "org" },
    },
    .{
        .type = "application/vnd.lotus-screencam",
        .extensions = &.{ "scm" },
    },
    .{
        .type = "application/vnd.lotus-wordpro",
        .extensions = &.{ "lwp" },
    },
    .{
        .type = "application/vnd.macports.portpkg",
        .extensions = &.{ "portpkg" },
    },
    .{
        .type = "application/vnd.mapbox-vector-tile",
        .extensions = &.{ "mvt" },
    },
    .{
        .type = "application/vnd.mcd",
        .extensions = &.{ "mcd" },
    },
    .{
        .type = "application/vnd.medcalcdata",
        .extensions = &.{ "mc1" },
    },
    .{
        .type = "application/vnd.mediastation.cdkey",
        .extensions = &.{ "cdkey" },
    },
    .{
        .type = "application/vnd.mfer",
        .extensions = &.{ "mwf" },
    },
    .{
        .type = "application/vnd.mfmp",
        .extensions = &.{ "mfm" },
    },
    .{
        .type = "application/vnd.micrografx.flo",
        .extensions = &.{ "flo" },
    },
    .{
        .type = "application/vnd.micrografx.igx",
        .extensions = &.{ "igx" },
    },
    .{
        .type = "application/vnd.mif",
        .extensions = &.{ "mif" },
    },
    .{
        .type = "application/vnd.mobius.daf",
        .extensions = &.{ "daf" },
    },
    .{
        .type = "application/vnd.mobius.dis",
        .extensions = &.{ "dis" },
    },
    .{
        .type = "application/vnd.mobius.mbk",
        .extensions = &.{ "mbk" },
    },
    .{
        .type = "application/vnd.mobius.mqy",
        .extensions = &.{ "mqy" },
    },
    .{
        .type = "application/vnd.mobius.msl",
        .extensions = &.{ "msl" },
    },
    .{
        .type = "application/vnd.mobius.plc",
        .extensions = &.{ "plc" },
    },
    .{
        .type = "application/vnd.mobius.txf",
        .extensions = &.{ "txf" },
    },
    .{
        .type = "application/vnd.mophun.application",
        .extensions = &.{ "mpn" },
    },
    .{
        .type = "application/vnd.mophun.certificate",
        .extensions = &.{ "mpc" },
    },
    .{
        .type = "application/vnd.mozilla.xul+xml",
        .extensions = &.{ "xul" },
    },
    .{
        .type = "application/vnd.ms-artgalry",
        .extensions = &.{ "cil" },
    },
    .{
        .type = "application/vnd.ms-cab-compressed",
        .extensions = &.{ "cab" },
    },
    .{
        .type = "application/vnd.ms-excel",
        .extensions = &.{ "xls", "xlm", "xla", "xlc", "xlt", "xlw" },
    },
    .{
        .type = "application/vnd.ms-excel.addin.macroenabled.12",
        .extensions = &.{ "xlam" },
    },
    .{
        .type = "application/vnd.ms-excel.sheet.binary.macroenabled.12",
        .extensions = &.{ "xlsb" },
    },
    .{
        .type = "application/vnd.ms-excel.sheet.macroenabled.12",
        .extensions = &.{ "xlsm" },
    },
    .{
        .type = "application/vnd.ms-excel.template.macroenabled.12",
        .extensions = &.{ "xltm" },
    },
    .{
        .type = "application/vnd.ms-fontobject",
        .extensions = &.{ "eot" },
    },
    .{
        .type = "application/vnd.ms-htmlhelp",
        .extensions = &.{ "chm" },
    },
    .{
        .type = "application/vnd.ms-ims",
        .extensions = &.{ "ims" },
    },
    .{
        .type = "application/vnd.ms-lrm",
        .extensions = &.{ "lrm" },
    },
    .{
        .type = "application/vnd.ms-officetheme",
        .extensions = &.{ "thmx" },
    },
    .{
        .type = "application/vnd.ms-outlook",
        .extensions = &.{ "msg" },
    },
    .{
        .type = "application/vnd.ms-pki.seccat",
        .extensions = &.{ "cat" },
    },
    .{
        .type = "application/vnd.ms-pki.stl",
        .extensions = &.{ "*stl" },
    },
    .{
        .type = "application/vnd.ms-powerpoint",
        .extensions = &.{ "ppt", "pps", "pot" },
    },
    .{
        .type = "application/vnd.ms-powerpoint.addin.macroenabled.12",
        .extensions = &.{ "ppam" },
    },
    .{
        .type = "application/vnd.ms-powerpoint.presentation.macroenabled.12",
        .extensions = &.{ "pptm" },
    },
    .{
        .type = "application/vnd.ms-powerpoint.slide.macroenabled.12",
        .extensions = &.{ "sldm" },
    },
    .{
        .type = "application/vnd.ms-powerpoint.slideshow.macroenabled.12",
        .extensions = &.{ "ppsm" },
    },
    .{
        .type = "application/vnd.ms-powerpoint.template.macroenabled.12",
        .extensions = &.{ "potm" },
    },
    .{
        .type = "application/vnd.ms-project",
        .extensions = &.{ "*mpp", "mpt" },
    },
    .{
        .type = "application/vnd.ms-visio.viewer",
        .extensions = &.{ "vdx" },
    },
    .{
        .type = "application/vnd.ms-word.document.macroenabled.12",
        .extensions = &.{ "docm" },
    },
    .{
        .type = "application/vnd.ms-word.template.macroenabled.12",
        .extensions = &.{ "dotm" },
    },
    .{
        .type = "application/vnd.ms-works",
        .extensions = &.{ "wps", "wks", "wcm", "wdb" },
    },
    .{
        .type = "application/vnd.ms-wpl",
        .extensions = &.{ "wpl" },
    },
    .{
        .type = "application/vnd.ms-xpsdocument",
        .extensions = &.{ "xps" },
    },
    .{
        .type = "application/vnd.mseq",
        .extensions = &.{ "mseq" },
    },
    .{
        .type = "application/vnd.musician",
        .extensions = &.{ "mus" },
    },
    .{
        .type = "application/vnd.muvee.style",
        .extensions = &.{ "msty" },
    },
    .{
        .type = "application/vnd.mynfc",
        .extensions = &.{ "taglet" },
    },
    .{
        .type = "application/vnd.nato.bindingdataobject+xml",
        .extensions = &.{ "bdo" },
    },
    .{
        .type = "application/vnd.neurolanguage.nlu",
        .extensions = &.{ "nlu" },
    },
    .{
        .type = "application/vnd.nitf",
        .extensions = &.{ "ntf", "nitf" },
    },
    .{
        .type = "application/vnd.noblenet-directory",
        .extensions = &.{ "nnd" },
    },
    .{
        .type = "application/vnd.noblenet-sealer",
        .extensions = &.{ "nns" },
    },
    .{
        .type = "application/vnd.noblenet-web",
        .extensions = &.{ "nnw" },
    },
    .{
        .type = "application/vnd.nokia.n-gage.ac+xml",
        .extensions = &.{ "*ac" },
    },
    .{
        .type = "application/vnd.nokia.n-gage.data",
        .extensions = &.{ "ngdat" },
    },
    .{
        .type = "application/vnd.nokia.n-gage.symbian.install",
        .extensions = &.{ "n-gage" },
    },
    .{
        .type = "application/vnd.nokia.radio-preset",
        .extensions = &.{ "rpst" },
    },
    .{
        .type = "application/vnd.nokia.radio-presets",
        .extensions = &.{ "rpss" },
    },
    .{
        .type = "application/vnd.novadigm.edm",
        .extensions = &.{ "edm" },
    },
    .{
        .type = "application/vnd.novadigm.edx",
        .extensions = &.{ "edx" },
    },
    .{
        .type = "application/vnd.novadigm.ext",
        .extensions = &.{ "ext" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.chart",
        .extensions = &.{ "odc" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.chart-template",
        .extensions = &.{ "otc" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.database",
        .extensions = &.{ "odb" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.formula",
        .extensions = &.{ "odf" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.formula-template",
        .extensions = &.{ "odft" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.graphics",
        .extensions = &.{ "odg" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.graphics-template",
        .extensions = &.{ "otg" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.image",
        .extensions = &.{ "odi" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.image-template",
        .extensions = &.{ "oti" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.presentation",
        .extensions = &.{ "odp" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.presentation-template",
        .extensions = &.{ "otp" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.spreadsheet",
        .extensions = &.{ "ods" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.spreadsheet-template",
        .extensions = &.{ "ots" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.text",
        .extensions = &.{ "odt" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.text-master",
        .extensions = &.{ "odm" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.text-template",
        .extensions = &.{ "ott" },
    },
    .{
        .type = "application/vnd.oasis.opendocument.text-web",
        .extensions = &.{ "oth" },
    },
    .{
        .type = "application/vnd.olpc-sugar",
        .extensions = &.{ "xo" },
    },
    .{
        .type = "application/vnd.oma.dd2+xml",
        .extensions = &.{ "dd2" },
    },
    .{
        .type = "application/vnd.openblox.game+xml",
        .extensions = &.{ "obgx" },
    },
    .{
        .type = "application/vnd.openofficeorg.extension",
        .extensions = &.{ "oxt" },
    },
    .{
        .type = "application/vnd.openstreetmap.data+xml",
        .extensions = &.{ "osm" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        .extensions = &.{ "pptx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.presentationml.slide",
        .extensions = &.{ "sldx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.presentationml.slideshow",
        .extensions = &.{ "ppsx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.presentationml.template",
        .extensions = &.{ "potx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        .extensions = &.{ "xlsx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.spreadsheetml.template",
        .extensions = &.{ "xltx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        .extensions = &.{ "docx" },
    },
    .{
        .type = "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
        .extensions = &.{ "dotx" },
    },
    .{
        .type = "application/vnd.osgeo.mapguide.package",
        .extensions = &.{ "mgp" },
    },
    .{
        .type = "application/vnd.osgi.dp",
        .extensions = &.{ "dp" },
    },
    .{
        .type = "application/vnd.osgi.subsystem",
        .extensions = &.{ "esa" },
    },
    .{
        .type = "application/vnd.palm",
        .extensions = &.{ "pdb", "pqa", "oprc" },
    },
    .{
        .type = "application/vnd.pawaafile",
        .extensions = &.{ "paw" },
    },
    .{
        .type = "application/vnd.pg.format",
        .extensions = &.{ "str" },
    },
    .{
        .type = "application/vnd.pg.osasli",
        .extensions = &.{ "ei6" },
    },
    .{
        .type = "application/vnd.picsel",
        .extensions = &.{ "efif" },
    },
    .{
        .type = "application/vnd.pmi.widget",
        .extensions = &.{ "wg" },
    },
    .{
        .type = "application/vnd.pocketlearn",
        .extensions = &.{ "plf" },
    },
    .{
        .type = "application/vnd.powerbuilder6",
        .extensions = &.{ "pbd" },
    },
    .{
        .type = "application/vnd.previewsystems.box",
        .extensions = &.{ "box" },
    },
    .{
        .type = "application/vnd.procrate.brushset",
        .extensions = &.{ "brushset" },
    },
    .{
        .type = "application/vnd.procreate.brush",
        .extensions = &.{ "brush" },
    },
    .{
        .type = "application/vnd.procreate.dream",
        .extensions = &.{ "drm" },
    },
    .{
        .type = "application/vnd.proteus.magazine",
        .extensions = &.{ "mgz" },
    },
    .{
        .type = "application/vnd.publishare-delta-tree",
        .extensions = &.{ "qps" },
    },
    .{
        .type = "application/vnd.pvi.ptid1",
        .extensions = &.{ "ptid" },
    },
    .{
        .type = "application/vnd.pwg-xhtml-print+xml",
        .extensions = &.{ "xhtm" },
    },
    .{
        .type = "application/vnd.quark.quarkxpress",
        .extensions = &.{ "qxd", "qxt", "qwd", "qwt", "qxl", "qxb" },
    },
    .{
        .type = "application/vnd.rar",
        .extensions = &.{ "rar" },
    },
    .{
        .type = "application/vnd.realvnc.bed",
        .extensions = &.{ "bed" },
    },
    .{
        .type = "application/vnd.recordare.musicxml",
        .extensions = &.{ "mxl" },
    },
    .{
        .type = "application/vnd.recordare.musicxml+xml",
        .extensions = &.{ "musicxml" },
    },
    .{
        .type = "application/vnd.rig.cryptonote",
        .extensions = &.{ "cryptonote" },
    },
    .{
        .type = "application/vnd.rim.cod",
        .extensions = &.{ "cod" },
    },
    .{
        .type = "application/vnd.rn-realmedia",
        .extensions = &.{ "rm" },
    },
    .{
        .type = "application/vnd.rn-realmedia-vbr",
        .extensions = &.{ "rmvb" },
    },
    .{
        .type = "application/vnd.route66.link66+xml",
        .extensions = &.{ "link66" },
    },
    .{
        .type = "application/vnd.sailingtracker.track",
        .extensions = &.{ "st" },
    },
    .{
        .type = "application/vnd.seemail",
        .extensions = &.{ "see" },
    },
    .{
        .type = "application/vnd.sema",
        .extensions = &.{ "sema" },
    },
    .{
        .type = "application/vnd.semd",
        .extensions = &.{ "semd" },
    },
    .{
        .type = "application/vnd.semf",
        .extensions = &.{ "semf" },
    },
    .{
        .type = "application/vnd.shana.informed.formdata",
        .extensions = &.{ "ifm" },
    },
    .{
        .type = "application/vnd.shana.informed.formtemplate",
        .extensions = &.{ "itp" },
    },
    .{
        .type = "application/vnd.shana.informed.interchange",
        .extensions = &.{ "iif" },
    },
    .{
        .type = "application/vnd.shana.informed.package",
        .extensions = &.{ "ipk" },
    },
    .{
        .type = "application/vnd.simtech-mindmapper",
        .extensions = &.{ "twd", "twds" },
    },
    .{
        .type = "application/vnd.smaf",
        .extensions = &.{ "mmf" },
    },
    .{
        .type = "application/vnd.smart.teacher",
        .extensions = &.{ "teacher" },
    },
    .{
        .type = "application/vnd.software602.filler.form+xml",
        .extensions = &.{ "fo" },
    },
    .{
        .type = "application/vnd.solent.sdkm+xml",
        .extensions = &.{ "sdkm", "sdkd" },
    },
    .{
        .type = "application/vnd.spotfire.dxp",
        .extensions = &.{ "dxp" },
    },
    .{
        .type = "application/vnd.spotfire.sfs",
        .extensions = &.{ "sfs" },
    },
    .{
        .type = "application/vnd.stardivision.calc",
        .extensions = &.{ "sdc" },
    },
    .{
        .type = "application/vnd.stardivision.draw",
        .extensions = &.{ "sda" },
    },
    .{
        .type = "application/vnd.stardivision.impress",
        .extensions = &.{ "sdd" },
    },
    .{
        .type = "application/vnd.stardivision.math",
        .extensions = &.{ "smf" },
    },
    .{
        .type = "application/vnd.stardivision.writer",
        .extensions = &.{ "sdw", "vor" },
    },
    .{
        .type = "application/vnd.stardivision.writer-global",
        .extensions = &.{ "sgl" },
    },
    .{
        .type = "application/vnd.stepmania.package",
        .extensions = &.{ "smzip" },
    },
    .{
        .type = "application/vnd.stepmania.stepchart",
        .extensions = &.{ "sm" },
    },
    .{
        .type = "application/vnd.sun.wadl+xml",
        .extensions = &.{ "wadl" },
    },
    .{
        .type = "application/vnd.sun.xml.calc",
        .extensions = &.{ "sxc" },
    },
    .{
        .type = "application/vnd.sun.xml.calc.template",
        .extensions = &.{ "stc" },
    },
    .{
        .type = "application/vnd.sun.xml.draw",
        .extensions = &.{ "sxd" },
    },
    .{
        .type = "application/vnd.sun.xml.draw.template",
        .extensions = &.{ "std" },
    },
    .{
        .type = "application/vnd.sun.xml.impress",
        .extensions = &.{ "sxi" },
    },
    .{
        .type = "application/vnd.sun.xml.impress.template",
        .extensions = &.{ "sti" },
    },
    .{
        .type = "application/vnd.sun.xml.math",
        .extensions = &.{ "sxm" },
    },
    .{
        .type = "application/vnd.sun.xml.writer",
        .extensions = &.{ "sxw" },
    },
    .{
        .type = "application/vnd.sun.xml.writer.global",
        .extensions = &.{ "sxg" },
    },
    .{
        .type = "application/vnd.sun.xml.writer.template",
        .extensions = &.{ "stw" },
    },
    .{
        .type = "application/vnd.sus-calendar",
        .extensions = &.{ "sus", "susp" },
    },
    .{
        .type = "application/vnd.svd",
        .extensions = &.{ "svd" },
    },
    .{
        .type = "application/vnd.symbian.install",
        .extensions = &.{ "sis", "sisx" },
    },
    .{
        .type = "application/vnd.syncml+xml",
        .extensions = &.{ "xsm" },
    },
    .{
        .type = "application/vnd.syncml.dm+wbxml",
        .extensions = &.{ "bdm" },
    },
    .{
        .type = "application/vnd.syncml.dm+xml",
        .extensions = &.{ "xdm" },
    },
    .{
        .type = "application/vnd.syncml.dmddf+xml",
        .extensions = &.{ "ddf" },
    },
    .{
        .type = "application/vnd.tao.intent-module-archive",
        .extensions = &.{ "tao" },
    },
    .{
        .type = "application/vnd.tcpdump.pcap",
        .extensions = &.{ "pcap", "cap", "dmp" },
    },
    .{
        .type = "application/vnd.tmobile-livetv",
        .extensions = &.{ "tmo" },
    },
    .{
        .type = "application/vnd.trid.tpt",
        .extensions = &.{ "tpt" },
    },
    .{
        .type = "application/vnd.triscape.mxs",
        .extensions = &.{ "mxs" },
    },
    .{
        .type = "application/vnd.trueapp",
        .extensions = &.{ "tra" },
    },
    .{
        .type = "application/vnd.ufdl",
        .extensions = &.{ "ufd", "ufdl" },
    },
    .{
        .type = "application/vnd.uiq.theme",
        .extensions = &.{ "utz" },
    },
    .{
        .type = "application/vnd.umajin",
        .extensions = &.{ "umj" },
    },
    .{
        .type = "application/vnd.unity",
        .extensions = &.{ "unityweb" },
    },
    .{
        .type = "application/vnd.uoml+xml",
        .extensions = &.{ "uoml", "uo" },
    },
    .{
        .type = "application/vnd.vcx",
        .extensions = &.{ "vcx" },
    },
    .{
        .type = "application/vnd.visio",
        .extensions = &.{ "vsd", "vst", "vss", "vsw", "vsdx", "vtx" },
    },
    .{
        .type = "application/vnd.visionary",
        .extensions = &.{ "vis" },
    },
    .{
        .type = "application/vnd.vsf",
        .extensions = &.{ "vsf" },
    },
    .{
        .type = "application/vnd.wap.wbxml",
        .extensions = &.{ "wbxml" },
    },
    .{
        .type = "application/vnd.wap.wmlc",
        .extensions = &.{ "wmlc" },
    },
    .{
        .type = "application/vnd.wap.wmlscriptc",
        .extensions = &.{ "wmlsc" },
    },
    .{
        .type = "application/vnd.webturbo",
        .extensions = &.{ "wtb" },
    },
    .{
        .type = "application/vnd.wolfram.player",
        .extensions = &.{ "nbp" },
    },
    .{
        .type = "application/vnd.wordperfect",
        .extensions = &.{ "wpd" },
    },
    .{
        .type = "application/vnd.wqd",
        .extensions = &.{ "wqd" },
    },
    .{
        .type = "application/vnd.wt.stf",
        .extensions = &.{ "stf" },
    },
    .{
        .type = "application/vnd.xara",
        .extensions = &.{ "xar" },
    },
    .{
        .type = "application/vnd.xfdl",
        .extensions = &.{ "xfdl" },
    },
    .{
        .type = "application/vnd.yamaha.hv-dic",
        .extensions = &.{ "hvd" },
    },
    .{
        .type = "application/vnd.yamaha.hv-script",
        .extensions = &.{ "hvs" },
    },
    .{
        .type = "application/vnd.yamaha.hv-voice",
        .extensions = &.{ "hvp" },
    },
    .{
        .type = "application/vnd.yamaha.openscoreformat",
        .extensions = &.{ "osf" },
    },
    .{
        .type = "application/vnd.yamaha.openscoreformat.osfpvg+xml",
        .extensions = &.{ "osfpvg" },
    },
    .{
        .type = "application/vnd.yamaha.smaf-audio",
        .extensions = &.{ "saf" },
    },
    .{
        .type = "application/vnd.yamaha.smaf-phrase",
        .extensions = &.{ "spf" },
    },
    .{
        .type = "application/vnd.yellowriver-custom-menu",
        .extensions = &.{ "cmp" },
    },
    .{
        .type = "application/vnd.zul",
        .extensions = &.{ "zir", "zirz" },
    },
    .{
        .type = "application/vnd.zzazz.deck+xml",
        .extensions = &.{ "zaz" },
    },
    .{
        .type = "application/x-7z-compressed",
        .extensions = &.{ "7z" },
    },
    .{
        .type = "application/x-abiword",
        .extensions = &.{ "abw" },
    },
    .{
        .type = "application/x-ace-compressed",
        .extensions = &.{ "ace" },
    },
    .{
        .type = "application/x-apple-diskimage",
        .extensions = &.{ "*dmg" },
    },
    .{
        .type = "application/x-arj",
        .extensions = &.{ "arj" },
    },
    .{
        .type = "application/x-authorware-bin",
        .extensions = &.{ "aab", "x32", "u32", "vox" },
    },
    .{
        .type = "application/x-authorware-map",
        .extensions = &.{ "aam" },
    },
    .{
        .type = "application/x-authorware-seg",
        .extensions = &.{ "aas" },
    },
    .{
        .type = "application/x-bcpio",
        .extensions = &.{ "bcpio" },
    },
    .{
        .type = "application/x-bdoc",
        .extensions = &.{ "*bdoc" },
    },
    .{
        .type = "application/x-bittorrent",
        .extensions = &.{ "torrent" },
    },
    .{
        .type = "application/x-blender",
        .extensions = &.{ "blend" },
    },
    .{
        .type = "application/x-blorb",
        .extensions = &.{ "blb", "blorb" },
    },
    .{
        .type = "application/x-bzip",
        .extensions = &.{ "bz" },
    },
    .{
        .type = "application/x-bzip2",
        .extensions = &.{ "bz2", "boz" },
    },
    .{
        .type = "application/x-cbr",
        .extensions = &.{ "cbr", "cba", "cbt", "cbz", "cb7" },
    },
    .{
        .type = "application/x-cdlink",
        .extensions = &.{ "vcd" },
    },
    .{
        .type = "application/x-cfs-compressed",
        .extensions = &.{ "cfs" },
    },
    .{
        .type = "application/x-chat",
        .extensions = &.{ "chat" },
    },
    .{
        .type = "application/x-chess-pgn",
        .extensions = &.{ "pgn" },
    },
    .{
        .type = "application/x-chrome-extension",
        .extensions = &.{ "crx" },
    },
    .{
        .type = "application/x-cocoa",
        .extensions = &.{ "cco" },
    },
    .{
        .type = "application/x-compressed",
        .extensions = &.{ "*rar" },
    },
    .{
        .type = "application/x-conference",
        .extensions = &.{ "nsc" },
    },
    .{
        .type = "application/x-cpio",
        .extensions = &.{ "cpio" },
    },
    .{
        .type = "application/x-csh",
        .extensions = &.{ "csh" },
    },
    .{
        .type = "application/x-debian-package",
        .extensions = &.{ "*deb", "udeb" },
    },
    .{
        .type = "application/x-dgc-compressed",
        .extensions = &.{ "dgc" },
    },
    .{
        .type = "application/x-director",
        .extensions = &.{ "dir", "dcr", "dxr", "cst", "cct", "cxt", "w3d", "fgd", "swa" },
    },
    .{
        .type = "application/x-doom",
        .extensions = &.{ "wad" },
    },
    .{
        .type = "application/x-dtbncx+xml",
        .extensions = &.{ "ncx" },
    },
    .{
        .type = "application/x-dtbook+xml",
        .extensions = &.{ "dtb" },
    },
    .{
        .type = "application/x-dtbresource+xml",
        .extensions = &.{ "res" },
    },
    .{
        .type = "application/x-dvi",
        .extensions = &.{ "dvi" },
    },
    .{
        .type = "application/x-envoy",
        .extensions = &.{ "evy" },
    },
    .{
        .type = "application/x-eva",
        .extensions = &.{ "eva" },
    },
    .{
        .type = "application/x-font-bdf",
        .extensions = &.{ "bdf" },
    },
    .{
        .type = "application/x-font-ghostscript",
        .extensions = &.{ "gsf" },
    },
    .{
        .type = "application/x-font-linux-psf",
        .extensions = &.{ "psf" },
    },
    .{
        .type = "application/x-font-pcf",
        .extensions = &.{ "pcf" },
    },
    .{
        .type = "application/x-font-snf",
        .extensions = &.{ "snf" },
    },
    .{
        .type = "application/x-font-type1",
        .extensions = &.{ "pfa", "pfb", "pfm", "afm" },
    },
    .{
        .type = "application/x-freearc",
        .extensions = &.{ "arc" },
    },
    .{
        .type = "application/x-futuresplash",
        .extensions = &.{ "spl" },
    },
    .{
        .type = "application/x-gca-compressed",
        .extensions = &.{ "gca" },
    },
    .{
        .type = "application/x-glulx",
        .extensions = &.{ "ulx" },
    },
    .{
        .type = "application/x-gnumeric",
        .extensions = &.{ "gnumeric" },
    },
    .{
        .type = "application/x-gramps-xml",
        .extensions = &.{ "gramps" },
    },
    .{
        .type = "application/x-gtar",
        .extensions = &.{ "gtar" },
    },
    .{
        .type = "application/x-hdf",
        .extensions = &.{ "hdf" },
    },
    .{
        .type = "application/x-httpd-php",
        .extensions = &.{ "php" },
    },
    .{
        .type = "application/x-install-instructions",
        .extensions = &.{ "install" },
    },
    .{
        .type = "application/x-ipynb+json",
        .extensions = &.{ "ipynb" },
    },
    .{
        .type = "application/x-iso9660-image",
        .extensions = &.{ "*iso" },
    },
    .{
        .type = "application/x-iwork-keynote-sffkey",
        .extensions = &.{ "*key" },
    },
    .{
        .type = "application/x-iwork-numbers-sffnumbers",
        .extensions = &.{ "*numbers" },
    },
    .{
        .type = "application/x-iwork-pages-sffpages",
        .extensions = &.{ "*pages" },
    },
    .{
        .type = "application/x-java-archive-diff",
        .extensions = &.{ "jardiff" },
    },
    .{
        .type = "application/x-java-jnlp-file",
        .extensions = &.{ "jnlp" },
    },
    .{
        .type = "application/x-keepass2",
        .extensions = &.{ "kdbx" },
    },
    .{
        .type = "application/x-latex",
        .extensions = &.{ "latex" },
    },
    .{
        .type = "application/x-lua-bytecode",
        .extensions = &.{ "luac" },
    },
    .{
        .type = "application/x-lzh-compressed",
        .extensions = &.{ "lzh", "lha" },
    },
    .{
        .type = "application/x-makeself",
        .extensions = &.{ "run" },
    },
    .{
        .type = "application/x-mie",
        .extensions = &.{ "mie" },
    },
    .{
        .type = "application/x-mobipocket-ebook",
        .extensions = &.{ "*prc", "mobi" },
    },
    .{
        .type = "application/x-ms-application",
        .extensions = &.{ "application" },
    },
    .{
        .type = "application/x-ms-shortcut",
        .extensions = &.{ "lnk" },
    },
    .{
        .type = "application/x-ms-wmd",
        .extensions = &.{ "wmd" },
    },
    .{
        .type = "application/x-ms-wmz",
        .extensions = &.{ "wmz" },
    },
    .{
        .type = "application/x-ms-xbap",
        .extensions = &.{ "xbap" },
    },
    .{
        .type = "application/x-msaccess",
        .extensions = &.{ "mdb" },
    },
    .{
        .type = "application/x-msbinder",
        .extensions = &.{ "obd" },
    },
    .{
        .type = "application/x-mscardfile",
        .extensions = &.{ "crd" },
    },
    .{
        .type = "application/x-msclip",
        .extensions = &.{ "clp" },
    },
    .{
        .type = "application/x-msdos-program",
        .extensions = &.{ "*exe" },
    },
    .{
        .type = "application/x-msdownload",
        .extensions = &.{ "*exe", "*dll", "com", "bat", "*msi" },
    },
    .{
        .type = "application/x-msmediaview",
        .extensions = &.{ "mvb", "m13", "m14" },
    },
    .{
        .type = "application/x-msmetafile",
        .extensions = &.{ "*wmf", "*wmz", "*emf", "emz" },
    },
    .{
        .type = "application/x-msmoney",
        .extensions = &.{ "mny" },
    },
    .{
        .type = "application/x-mspublisher",
        .extensions = &.{ "pub" },
    },
    .{
        .type = "application/x-msschedule",
        .extensions = &.{ "scd" },
    },
    .{
        .type = "application/x-msterminal",
        .extensions = &.{ "trm" },
    },
    .{
        .type = "application/x-mswrite",
        .extensions = &.{ "wri" },
    },
    .{
        .type = "application/x-netcdf",
        .extensions = &.{ "nc", "cdf" },
    },
    .{
        .type = "application/x-ns-proxy-autoconfig",
        .extensions = &.{ "pac" },
    },
    .{
        .type = "application/x-nzb",
        .extensions = &.{ "nzb" },
    },
    .{
        .type = "application/x-perl",
        .extensions = &.{ "pl", "pm" },
    },
    .{
        .type = "application/x-pilot",
        .extensions = &.{ "*prc", "*pdb" },
    },
    .{
        .type = "application/x-pkcs12",
        .extensions = &.{ "p12", "pfx" },
    },
    .{
        .type = "application/x-pkcs7-certificates",
        .extensions = &.{ "p7b", "spc" },
    },
    .{
        .type = "application/x-pkcs7-certreqresp",
        .extensions = &.{ "p7r" },
    },
    .{
        .type = "application/x-rar-compressed",
        .extensions = &.{ "*rar" },
    },
    .{
        .type = "application/x-redhat-package-manager",
        .extensions = &.{ "rpm" },
    },
    .{
        .type = "application/x-research-info-systems",
        .extensions = &.{ "ris" },
    },
    .{
        .type = "application/x-sea",
        .extensions = &.{ "sea" },
    },
    .{
        .type = "application/x-sh",
        .extensions = &.{ "sh" },
    },
    .{
        .type = "application/x-shar",
        .extensions = &.{ "shar" },
    },
    .{
        .type = "application/x-shockwave-flash",
        .extensions = &.{ "swf" },
    },
    .{
        .type = "application/x-silverlight-app",
        .extensions = &.{ "xap" },
    },
    .{
        .type = "application/x-sql",
        .extensions = &.{ "*sql" },
    },
    .{
        .type = "application/x-stuffit",
        .extensions = &.{ "sit" },
    },
    .{
        .type = "application/x-stuffitx",
        .extensions = &.{ "sitx" },
    },
    .{
        .type = "application/x-subrip",
        .extensions = &.{ "srt" },
    },
    .{
        .type = "application/x-sv4cpio",
        .extensions = &.{ "sv4cpio" },
    },
    .{
        .type = "application/x-sv4crc",
        .extensions = &.{ "sv4crc" },
    },
    .{
        .type = "application/x-t3vm-image",
        .extensions = &.{ "t3" },
    },
    .{
        .type = "application/x-tads",
        .extensions = &.{ "gam" },
    },
    .{
        .type = "application/x-tar",
        .extensions = &.{ "tar" },
    },
    .{
        .type = "application/x-tcl",
        .extensions = &.{ "tcl", "tk" },
    },
    .{
        .type = "application/x-tex",
        .extensions = &.{ "tex" },
    },
    .{
        .type = "application/x-tex-tfm",
        .extensions = &.{ "tfm" },
    },
    .{
        .type = "application/x-texinfo",
        .extensions = &.{ "texinfo", "texi" },
    },
    .{
        .type = "application/x-tgif",
        .extensions = &.{ "*obj" },
    },
    .{
        .type = "application/x-ustar",
        .extensions = &.{ "ustar" },
    },
    .{
        .type = "application/x-virtualbox-hdd",
        .extensions = &.{ "hdd" },
    },
    .{
        .type = "application/x-virtualbox-ova",
        .extensions = &.{ "ova" },
    },
    .{
        .type = "application/x-virtualbox-ovf",
        .extensions = &.{ "ovf" },
    },
    .{
        .type = "application/x-virtualbox-vbox",
        .extensions = &.{ "vbox" },
    },
    .{
        .type = "application/x-virtualbox-vbox-extpack",
        .extensions = &.{ "vbox-extpack" },
    },
    .{
        .type = "application/x-virtualbox-vdi",
        .extensions = &.{ "vdi" },
    },
    .{
        .type = "application/x-virtualbox-vhd",
        .extensions = &.{ "vhd" },
    },
    .{
        .type = "application/x-virtualbox-vmdk",
        .extensions = &.{ "vmdk" },
    },
    .{
        .type = "application/x-wais-source",
        .extensions = &.{ "src" },
    },
    .{
        .type = "application/x-web-app-manifest+json",
        .extensions = &.{ "webapp" },
    },
    .{
        .type = "application/x-x509-ca-cert",
        .extensions = &.{ "der", "crt", "pem" },
    },
    .{
        .type = "application/x-xfig",
        .extensions = &.{ "fig" },
    },
    .{
        .type = "application/x-xliff+xml",
        .extensions = &.{ "*xlf" },
    },
    .{
        .type = "application/x-xpinstall",
        .extensions = &.{ "xpi" },
    },
    .{
        .type = "application/x-xz",
        .extensions = &.{ "xz" },
    },
    .{
        .type = "application/x-zip-compressed",
        .extensions = &.{ "*zip" },
    },
    .{
        .type = "application/x-zmachine",
        .extensions = &.{ "z1", "z2", "z3", "z4", "z5", "z6", "z7", "z8" },
    },
    .{
        .type = "audio/vnd.dece.audio",
        .extensions = &.{ "uva", "uvva" },
    },
    .{
        .type = "audio/vnd.digital-winds",
        .extensions = &.{ "eol" },
    },
    .{
        .type = "audio/vnd.dra",
        .extensions = &.{ "dra" },
    },
    .{
        .type = "audio/vnd.dts",
        .extensions = &.{ "dts" },
    },
    .{
        .type = "audio/vnd.dts.hd",
        .extensions = &.{ "dtshd" },
    },
    .{
        .type = "audio/vnd.lucent.voice",
        .extensions = &.{ "lvp" },
    },
    .{
        .type = "audio/vnd.ms-playready.media.pya",
        .extensions = &.{ "pya" },
    },
    .{
        .type = "audio/vnd.nuera.ecelp4800",
        .extensions = &.{ "ecelp4800" },
    },
    .{
        .type = "audio/vnd.nuera.ecelp7470",
        .extensions = &.{ "ecelp7470" },
    },
    .{
        .type = "audio/vnd.nuera.ecelp9600",
        .extensions = &.{ "ecelp9600" },
    },
    .{
        .type = "audio/vnd.rip",
        .extensions = &.{ "rip" },
    },
    .{
        .type = "audio/x-aac",
        .extensions = &.{ "*aac" },
    },
    .{
        .type = "audio/x-aiff",
        .extensions = &.{ "aif", "aiff", "aifc" },
    },
    .{
        .type = "audio/x-caf",
        .extensions = &.{ "caf" },
    },
    .{
        .type = "audio/x-flac",
        .extensions = &.{ "flac" },
    },
    .{
        .type = "audio/x-m4a",
        .extensions = &.{ "*m4a" },
    },
    .{
        .type = "audio/x-matroska",
        .extensions = &.{ "mka" },
    },
    .{
        .type = "audio/x-mpegurl",
        .extensions = &.{ "m3u" },
    },
    .{
        .type = "audio/x-ms-wax",
        .extensions = &.{ "wax" },
    },
    .{
        .type = "audio/x-ms-wma",
        .extensions = &.{ "wma" },
    },
    .{
        .type = "audio/x-pn-realaudio",
        .extensions = &.{ "ram", "ra" },
    },
    .{
        .type = "audio/x-pn-realaudio-plugin",
        .extensions = &.{ "rmp" },
    },
    .{
        .type = "audio/x-realaudio",
        .extensions = &.{ "*ra" },
    },
    .{
        .type = "audio/x-wav",
        .extensions = &.{ "*wav" },
    },
    .{
        .type = "chemical/x-cdx",
        .extensions = &.{ "cdx" },
    },
    .{
        .type = "chemical/x-cif",
        .extensions = &.{ "cif" },
    },
    .{
        .type = "chemical/x-cmdf",
        .extensions = &.{ "cmdf" },
    },
    .{
        .type = "chemical/x-cml",
        .extensions = &.{ "cml" },
    },
    .{
        .type = "chemical/x-csml",
        .extensions = &.{ "csml" },
    },
    .{
        .type = "chemical/x-xyz",
        .extensions = &.{ "xyz" },
    },
    .{
        .type = "image/prs.btif",
        .extensions = &.{ "btif", "btf" },
    },
    .{
        .type = "image/prs.pti",
        .extensions = &.{ "pti" },
    },
    .{
        .type = "image/vnd.adobe.photoshop",
        .extensions = &.{ "psd" },
    },
    .{
        .type = "image/vnd.airzip.accelerator.azv",
        .extensions = &.{ "azv" },
    },
    .{
        .type = "image/vnd.blockfact.facti",
        .extensions = &.{ "facti" },
    },
    .{
        .type = "image/vnd.dece.graphic",
        .extensions = &.{ "uvi", "uvvi", "uvg", "uvvg" },
    },
    .{
        .type = "image/vnd.djvu",
        .extensions = &.{ "djvu", "djv" },
    },
    .{
        .type = "image/vnd.dvb.subtitle",
        .extensions = &.{ "*sub" },
    },
    .{
        .type = "image/vnd.dwg",
        .extensions = &.{ "dwg" },
    },
    .{
        .type = "image/vnd.dxf",
        .extensions = &.{ "dxf" },
    },
    .{
        .type = "image/vnd.fastbidsheet",
        .extensions = &.{ "fbs" },
    },
    .{
        .type = "image/vnd.fpx",
        .extensions = &.{ "fpx" },
    },
    .{
        .type = "image/vnd.fst",
        .extensions = &.{ "fst" },
    },
    .{
        .type = "image/vnd.fujixerox.edmics-mmr",
        .extensions = &.{ "mmr" },
    },
    .{
        .type = "image/vnd.fujixerox.edmics-rlc",
        .extensions = &.{ "rlc" },
    },
    .{
        .type = "image/vnd.microsoft.icon",
        .extensions = &.{ "ico" },
    },
    .{
        .type = "image/vnd.ms-dds",
        .extensions = &.{ "dds" },
    },
    .{
        .type = "image/vnd.ms-modi",
        .extensions = &.{ "mdi" },
    },
    .{
        .type = "image/vnd.ms-photo",
        .extensions = &.{ "wdp" },
    },
    .{
        .type = "image/vnd.net-fpx",
        .extensions = &.{ "npx" },
    },
    .{
        .type = "image/vnd.pco.b16",
        .extensions = &.{ "b16" },
    },
    .{
        .type = "image/vnd.tencent.tap",
        .extensions = &.{ "tap" },
    },
    .{
        .type = "image/vnd.valve.source.texture",
        .extensions = &.{ "vtf" },
    },
    .{
        .type = "image/vnd.wap.wbmp",
        .extensions = &.{ "wbmp" },
    },
    .{
        .type = "image/vnd.xiff",
        .extensions = &.{ "xif" },
    },
    .{
        .type = "image/vnd.zbrush.pcx",
        .extensions = &.{ "pcx" },
    },
    .{
        .type = "image/x-3ds",
        .extensions = &.{ "3ds" },
    },
    .{
        .type = "image/x-adobe-dng",
        .extensions = &.{ "dng" },
    },
    .{
        .type = "image/x-cmu-raster",
        .extensions = &.{ "ras" },
    },
    .{
        .type = "image/x-cmx",
        .extensions = &.{ "cmx" },
    },
    .{
        .type = "image/x-freehand",
        .extensions = &.{ "fh", "fhc", "fh4", "fh5", "fh7" },
    },
    .{
        .type = "image/x-icon",
        .extensions = &.{ "*ico" },
    },
    .{
        .type = "image/x-jng",
        .extensions = &.{ "jng" },
    },
    .{
        .type = "image/x-mrsid-image",
        .extensions = &.{ "sid" },
    },
    .{
        .type = "image/x-ms-bmp",
        .extensions = &.{ "*bmp" },
    },
    .{
        .type = "image/x-pcx",
        .extensions = &.{ "*pcx" },
    },
    .{
        .type = "image/x-pict",
        .extensions = &.{ "pic", "pct" },
    },
    .{
        .type = "image/x-portable-anymap",
        .extensions = &.{ "pnm" },
    },
    .{
        .type = "image/x-portable-bitmap",
        .extensions = &.{ "pbm" },
    },
    .{
        .type = "image/x-portable-graymap",
        .extensions = &.{ "pgm" },
    },
    .{
        .type = "image/x-portable-pixmap",
        .extensions = &.{ "ppm" },
    },
    .{
        .type = "image/x-rgb",
        .extensions = &.{ "rgb" },
    },
    .{
        .type = "image/x-tga",
        .extensions = &.{ "tga" },
    },
    .{
        .type = "image/x-xbitmap",
        .extensions = &.{ "xbm" },
    },
    .{
        .type = "image/x-xpixmap",
        .extensions = &.{ "xpm" },
    },
    .{
        .type = "image/x-xwindowdump",
        .extensions = &.{ "xwd" },
    },
    .{
        .type = "message/vnd.wfa.wsc",
        .extensions = &.{ "wsc" },
    },
    .{
        .type = "model/vnd.bary",
        .extensions = &.{ "bary" },
    },
    .{
        .type = "model/vnd.cld",
        .extensions = &.{ "cld" },
    },
    .{
        .type = "model/vnd.collada+xml",
        .extensions = &.{ "dae" },
    },
    .{
        .type = "model/vnd.dwf",
        .extensions = &.{ "dwf" },
    },
    .{
        .type = "model/vnd.gdl",
        .extensions = &.{ "gdl" },
    },
    .{
        .type = "model/vnd.gtw",
        .extensions = &.{ "gtw" },
    },
    .{
        .type = "model/vnd.mts",
        .extensions = &.{ "*mts" },
    },
    .{
        .type = "model/vnd.opengex",
        .extensions = &.{ "ogex" },
    },
    .{
        .type = "model/vnd.parasolid.transmit.binary",
        .extensions = &.{ "x_b" },
    },
    .{
        .type = "model/vnd.parasolid.transmit.text",
        .extensions = &.{ "x_t" },
    },
    .{
        .type = "model/vnd.pytha.pyox",
        .extensions = &.{ "pyo", "pyox" },
    },
    .{
        .type = "model/vnd.sap.vds",
        .extensions = &.{ "vds" },
    },
    .{
        .type = "model/vnd.usda",
        .extensions = &.{ "usda" },
    },
    .{
        .type = "model/vnd.usdz+zip",
        .extensions = &.{ "usdz" },
    },
    .{
        .type = "model/vnd.valve.source.compiled-map",
        .extensions = &.{ "bsp" },
    },
    .{
        .type = "model/vnd.vtu",
        .extensions = &.{ "vtu" },
    },
    .{
        .type = "text/prs.lines.tag",
        .extensions = &.{ "dsc" },
    },
    .{
        .type = "text/vnd.curl",
        .extensions = &.{ "curl" },
    },
    .{
        .type = "text/vnd.curl.dcurl",
        .extensions = &.{ "dcurl" },
    },
    .{
        .type = "text/vnd.curl.mcurl",
        .extensions = &.{ "mcurl" },
    },
    .{
        .type = "text/vnd.curl.scurl",
        .extensions = &.{ "scurl" },
    },
    .{
        .type = "text/vnd.dvb.subtitle",
        .extensions = &.{ "sub" },
    },
    .{
        .type = "text/vnd.familysearch.gedcom",
        .extensions = &.{ "ged" },
    },
    .{
        .type = "text/vnd.fly",
        .extensions = &.{ "fly" },
    },
    .{
        .type = "text/vnd.fmi.flexstor",
        .extensions = &.{ "flx" },
    },
    .{
        .type = "text/vnd.graphviz",
        .extensions = &.{ "gv" },
    },
    .{
        .type = "text/vnd.in3d.3dml",
        .extensions = &.{ "3dml" },
    },
    .{
        .type = "text/vnd.in3d.spot",
        .extensions = &.{ "spot" },
    },
    .{
        .type = "text/vnd.sun.j2me.app-descriptor",
        .extensions = &.{ "jad" },
    },
    .{
        .type = "text/vnd.wap.wml",
        .extensions = &.{ "wml" },
    },
    .{
        .type = "text/vnd.wap.wmlscript",
        .extensions = &.{ "wmls" },
    },
    .{
        .type = "text/x-asm",
        .extensions = &.{ "s", "asm" },
    },
    .{
        .type = "text/x-c",
        .extensions = &.{ "c", "cc", "cxx", "cpp", "h", "hh", "dic" },
    },
    .{
        .type = "text/x-component",
        .extensions = &.{ "htc" },
    },
    .{
        .type = "text/x-fortran",
        .extensions = &.{ "f", "for", "f77", "f90" },
    },
    .{
        .type = "text/x-handlebars-template",
        .extensions = &.{ "hbs" },
    },
    .{
        .type = "text/x-java-source",
        .extensions = &.{ "java" },
    },
    .{
        .type = "text/x-lua",
        .extensions = &.{ "lua" },
    },
    .{
        .type = "text/x-markdown",
        .extensions = &.{ "mkd" },
    },
    .{
        .type = "text/x-nfo",
        .extensions = &.{ "nfo" },
    },
    .{
        .type = "text/x-opml",
        .extensions = &.{ "opml" },
    },
    .{
        .type = "text/x-org",
        .extensions = &.{ "*org" },
    },
    .{
        .type = "text/x-pascal",
        .extensions = &.{ "p", "pas" },
    },
    .{
        .type = "text/x-processing",
        .extensions = &.{ "pde" },
    },
    .{
        .type = "text/x-sass",
        .extensions = &.{ "sass" },
    },
    .{
        .type = "text/x-scss",
        .extensions = &.{ "scss" },
    },
    .{
        .type = "text/x-setext",
        .extensions = &.{ "etx" },
    },
    .{
        .type = "text/x-sfv",
        .extensions = &.{ "sfv" },
    },
    .{
        .type = "text/x-suse-ymp",
        .extensions = &.{ "ymp" },
    },
    .{
        .type = "text/x-uuencode",
        .extensions = &.{ "uu" },
    },
    .{
        .type = "text/x-vcalendar",
        .extensions = &.{ "vcs" },
    },
    .{
        .type = "text/x-vcard",
        .extensions = &.{ "vcf" },
    },
    .{
        .type = "video/vnd.dece.hd",
        .extensions = &.{ "uvh", "uvvh" },
    },
    .{
        .type = "video/vnd.dece.mobile",
        .extensions = &.{ "uvm", "uvvm" },
    },
    .{
        .type = "video/vnd.dece.pd",
        .extensions = &.{ "uvp", "uvvp" },
    },
    .{
        .type = "video/vnd.dece.sd",
        .extensions = &.{ "uvs", "uvvs" },
    },
    .{
        .type = "video/vnd.dece.video",
        .extensions = &.{ "uvv", "uvvv" },
    },
    .{
        .type = "video/vnd.dvb.file",
        .extensions = &.{ "dvb" },
    },
    .{
        .type = "video/vnd.fvt",
        .extensions = &.{ "fvt" },
    },
    .{
        .type = "video/vnd.mpegurl",
        .extensions = &.{ "mxu", "m4u" },
    },
    .{
        .type = "video/vnd.ms-playready.media.pyv",
        .extensions = &.{ "pyv" },
    },
    .{
        .type = "video/vnd.uvvu.mp4",
        .extensions = &.{ "uvu", "uvvu" },
    },
    .{
        .type = "video/vnd.vivo",
        .extensions = &.{ "viv" },
    },
    .{
        .type = "video/x-f4v",
        .extensions = &.{ "f4v" },
    },
    .{
        .type = "video/x-fli",
        .extensions = &.{ "fli" },
    },
    .{
        .type = "video/x-flv",
        .extensions = &.{ "flv" },
    },
    .{
        .type = "video/x-m4v",
        .extensions = &.{ "m4v" },
    },
    .{
        .type = "video/x-matroska",
        .extensions = &.{ "mkv", "mk3d", "mks" },
    },
    .{
        .type = "video/x-mng",
        .extensions = &.{ "mng" },
    },
    .{
        .type = "video/x-ms-asf",
        .extensions = &.{ "asf", "asx" },
    },
    .{
        .type = "video/x-ms-vob",
        .extensions = &.{ "vob" },
    },
    .{
        .type = "video/x-ms-wm",
        .extensions = &.{ "wm" },
    },
    .{
        .type = "video/x-ms-wmv",
        .extensions = &.{ "wmv" },
    },
    .{
        .type = "video/x-ms-wmx",
        .extensions = &.{ "wmx" },
    },
    .{
        .type = "video/x-ms-wvx",
        .extensions = &.{ "wvx" },
    },
    .{
        .type = "video/x-msvideo",
        .extensions = &.{ "avi" },
    },
    .{
        .type = "video/x-sgi-movie",
        .extensions = &.{ "movie" },
    },
    .{
        .type = "video/x-smv",
        .extensions = &.{ "smv" },
    },
    .{
        .type = "x-conference/x-cooltalk",
        .extensions = &.{ "ice" },
    },
};
