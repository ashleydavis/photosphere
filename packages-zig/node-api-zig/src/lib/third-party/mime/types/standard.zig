//
// Port of mime 4.1.0 types/standard.ts: the standard MIME types and their extensions, in the order the file lists them.
//
// mime (c) 2023 Robert Kieffer, MIT license.
//

const TypeMapEntry = @import("../Mime.zig").TypeMapEntry;

//
// The types (TypeScript: the `types` object, as a list of its entries in order).
//
pub const types = [_]TypeMapEntry{
    .{
        .type = "application/andrew-inset",
        .extensions = &.{ "ez" },
    },
    .{
        .type = "application/appinstaller",
        .extensions = &.{ "appinstaller" },
    },
    .{
        .type = "application/applixware",
        .extensions = &.{ "aw" },
    },
    .{
        .type = "application/appx",
        .extensions = &.{ "appx" },
    },
    .{
        .type = "application/appxbundle",
        .extensions = &.{ "appxbundle" },
    },
    .{
        .type = "application/atom+xml",
        .extensions = &.{ "atom" },
    },
    .{
        .type = "application/atomcat+xml",
        .extensions = &.{ "atomcat" },
    },
    .{
        .type = "application/atomdeleted+xml",
        .extensions = &.{ "atomdeleted" },
    },
    .{
        .type = "application/atomsvc+xml",
        .extensions = &.{ "atomsvc" },
    },
    .{
        .type = "application/atsc-dwd+xml",
        .extensions = &.{ "dwd" },
    },
    .{
        .type = "application/atsc-held+xml",
        .extensions = &.{ "held" },
    },
    .{
        .type = "application/atsc-rsat+xml",
        .extensions = &.{ "rsat" },
    },
    .{
        .type = "application/automationml-aml+xml",
        .extensions = &.{ "aml" },
    },
    .{
        .type = "application/automationml-amlx+zip",
        .extensions = &.{ "amlx" },
    },
    .{
        .type = "application/bdoc",
        .extensions = &.{ "bdoc" },
    },
    .{
        .type = "application/calendar+xml",
        .extensions = &.{ "xcs" },
    },
    .{
        .type = "application/ccxml+xml",
        .extensions = &.{ "ccxml" },
    },
    .{
        .type = "application/cdfx+xml",
        .extensions = &.{ "cdfx" },
    },
    .{
        .type = "application/cdmi-capability",
        .extensions = &.{ "cdmia" },
    },
    .{
        .type = "application/cdmi-container",
        .extensions = &.{ "cdmic" },
    },
    .{
        .type = "application/cdmi-domain",
        .extensions = &.{ "cdmid" },
    },
    .{
        .type = "application/cdmi-object",
        .extensions = &.{ "cdmio" },
    },
    .{
        .type = "application/cdmi-queue",
        .extensions = &.{ "cdmiq" },
    },
    .{
        .type = "application/cpl+xml",
        .extensions = &.{ "cpl" },
    },
    .{
        .type = "application/cu-seeme",
        .extensions = &.{ "cu" },
    },
    .{
        .type = "application/cwl",
        .extensions = &.{ "cwl" },
    },
    .{
        .type = "application/dash+xml",
        .extensions = &.{ "mpd" },
    },
    .{
        .type = "application/dash-patch+xml",
        .extensions = &.{ "mpp" },
    },
    .{
        .type = "application/davmount+xml",
        .extensions = &.{ "davmount" },
    },
    .{
        .type = "application/dicom",
        .extensions = &.{ "dcm" },
    },
    .{
        .type = "application/docbook+xml",
        .extensions = &.{ "dbk" },
    },
    .{
        .type = "application/dssc+der",
        .extensions = &.{ "dssc" },
    },
    .{
        .type = "application/dssc+xml",
        .extensions = &.{ "xdssc" },
    },
    .{
        .type = "application/ecmascript",
        .extensions = &.{ "ecma" },
    },
    .{
        .type = "application/emma+xml",
        .extensions = &.{ "emma" },
    },
    .{
        .type = "application/emotionml+xml",
        .extensions = &.{ "emotionml" },
    },
    .{
        .type = "application/epub+zip",
        .extensions = &.{ "epub" },
    },
    .{
        .type = "application/exi",
        .extensions = &.{ "exi" },
    },
    .{
        .type = "application/express",
        .extensions = &.{ "exp" },
    },
    .{
        .type = "application/fdf",
        .extensions = &.{ "fdf" },
    },
    .{
        .type = "application/fdt+xml",
        .extensions = &.{ "fdt" },
    },
    .{
        .type = "application/font-tdpfr",
        .extensions = &.{ "pfr" },
    },
    .{
        .type = "application/geo+json",
        .extensions = &.{ "geojson" },
    },
    .{
        .type = "application/gml+xml",
        .extensions = &.{ "gml" },
    },
    .{
        .type = "application/gpx+xml",
        .extensions = &.{ "gpx" },
    },
    .{
        .type = "application/gxf",
        .extensions = &.{ "gxf" },
    },
    .{
        .type = "application/gzip",
        .extensions = &.{ "gz" },
    },
    .{
        .type = "application/hjson",
        .extensions = &.{ "hjson" },
    },
    .{
        .type = "application/hyperstudio",
        .extensions = &.{ "stk" },
    },
    .{
        .type = "application/inkml+xml",
        .extensions = &.{ "ink", "inkml" },
    },
    .{
        .type = "application/ipfix",
        .extensions = &.{ "ipfix" },
    },
    .{
        .type = "application/its+xml",
        .extensions = &.{ "its" },
    },
    .{
        .type = "application/java-archive",
        .extensions = &.{ "jar", "war", "ear" },
    },
    .{
        .type = "application/java-serialized-object",
        .extensions = &.{ "ser" },
    },
    .{
        .type = "application/java-vm",
        .extensions = &.{ "class" },
    },
    .{
        .type = "application/javascript",
        .extensions = &.{ "*js" },
    },
    .{
        .type = "application/json",
        .extensions = &.{ "json", "map" },
    },
    .{
        .type = "application/json5",
        .extensions = &.{ "json5" },
    },
    .{
        .type = "application/jsonml+json",
        .extensions = &.{ "jsonml" },
    },
    .{
        .type = "application/ld+json",
        .extensions = &.{ "jsonld" },
    },
    .{
        .type = "application/lgr+xml",
        .extensions = &.{ "lgr" },
    },
    .{
        .type = "application/lost+xml",
        .extensions = &.{ "lostxml" },
    },
    .{
        .type = "application/mac-binhex40",
        .extensions = &.{ "hqx" },
    },
    .{
        .type = "application/mac-compactpro",
        .extensions = &.{ "cpt" },
    },
    .{
        .type = "application/mads+xml",
        .extensions = &.{ "mads" },
    },
    .{
        .type = "application/manifest+json",
        .extensions = &.{ "webmanifest" },
    },
    .{
        .type = "application/marc",
        .extensions = &.{ "mrc" },
    },
    .{
        .type = "application/marcxml+xml",
        .extensions = &.{ "mrcx" },
    },
    .{
        .type = "application/mathematica",
        .extensions = &.{ "ma", "nb", "mb" },
    },
    .{
        .type = "application/mathml+xml",
        .extensions = &.{ "mathml" },
    },
    .{
        .type = "application/mbox",
        .extensions = &.{ "mbox" },
    },
    .{
        .type = "application/media-policy-dataset+xml",
        .extensions = &.{ "mpf" },
    },
    .{
        .type = "application/mediaservercontrol+xml",
        .extensions = &.{ "mscml" },
    },
    .{
        .type = "application/metalink+xml",
        .extensions = &.{ "metalink" },
    },
    .{
        .type = "application/metalink4+xml",
        .extensions = &.{ "meta4" },
    },
    .{
        .type = "application/mets+xml",
        .extensions = &.{ "mets" },
    },
    .{
        .type = "application/mmt-aei+xml",
        .extensions = &.{ "maei" },
    },
    .{
        .type = "application/mmt-usd+xml",
        .extensions = &.{ "musd" },
    },
    .{
        .type = "application/mods+xml",
        .extensions = &.{ "mods" },
    },
    .{
        .type = "application/mp21",
        .extensions = &.{ "m21", "mp21" },
    },
    .{
        .type = "application/mp4",
        .extensions = &.{ "*mp4", "*mpg4", "mp4s", "m4p" },
    },
    .{
        .type = "application/msix",
        .extensions = &.{ "msix" },
    },
    .{
        .type = "application/msixbundle",
        .extensions = &.{ "msixbundle" },
    },
    .{
        .type = "application/msword",
        .extensions = &.{ "doc", "dot" },
    },
    .{
        .type = "application/mxf",
        .extensions = &.{ "mxf" },
    },
    .{
        .type = "application/n-quads",
        .extensions = &.{ "nq" },
    },
    .{
        .type = "application/n-triples",
        .extensions = &.{ "nt" },
    },
    .{
        .type = "application/node",
        .extensions = &.{ "cjs" },
    },
    .{
        .type = "application/octet-stream",
        .extensions = &.{ "bin", "dms", "lrf", "mar", "so", "dist", "distz", "pkg", "bpk", "dump", "elc", "deploy", "exe", "dll", "deb", "dmg", "iso", "img", "msi", "msp", "msm", "buffer" },
    },
    .{
        .type = "application/oda",
        .extensions = &.{ "oda" },
    },
    .{
        .type = "application/oebps-package+xml",
        .extensions = &.{ "opf" },
    },
    .{
        .type = "application/ogg",
        .extensions = &.{ "ogx" },
    },
    .{
        .type = "application/omdoc+xml",
        .extensions = &.{ "omdoc" },
    },
    .{
        .type = "application/onenote",
        .extensions = &.{ "onetoc", "onetoc2", "onetmp", "onepkg", "one", "onea" },
    },
    .{
        .type = "application/oxps",
        .extensions = &.{ "oxps" },
    },
    .{
        .type = "application/p2p-overlay+xml",
        .extensions = &.{ "relo" },
    },
    .{
        .type = "application/patch-ops-error+xml",
        .extensions = &.{ "xer" },
    },
    .{
        .type = "application/pdf",
        .extensions = &.{ "pdf" },
    },
    .{
        .type = "application/pgp-encrypted",
        .extensions = &.{ "pgp" },
    },
    .{
        .type = "application/pgp-keys",
        .extensions = &.{ "asc" },
    },
    .{
        .type = "application/pgp-signature",
        .extensions = &.{ "sig", "*asc" },
    },
    .{
        .type = "application/pics-rules",
        .extensions = &.{ "prf" },
    },
    .{
        .type = "application/pkcs10",
        .extensions = &.{ "p10" },
    },
    .{
        .type = "application/pkcs7-mime",
        .extensions = &.{ "p7m", "p7c" },
    },
    .{
        .type = "application/pkcs7-signature",
        .extensions = &.{ "p7s" },
    },
    .{
        .type = "application/pkcs8",
        .extensions = &.{ "p8" },
    },
    .{
        .type = "application/pkix-attr-cert",
        .extensions = &.{ "ac" },
    },
    .{
        .type = "application/pkix-cert",
        .extensions = &.{ "cer" },
    },
    .{
        .type = "application/pkix-crl",
        .extensions = &.{ "crl" },
    },
    .{
        .type = "application/pkix-pkipath",
        .extensions = &.{ "pkipath" },
    },
    .{
        .type = "application/pkixcmp",
        .extensions = &.{ "pki" },
    },
    .{
        .type = "application/pls+xml",
        .extensions = &.{ "pls" },
    },
    .{
        .type = "application/postscript",
        .extensions = &.{ "ai", "eps", "ps" },
    },
    .{
        .type = "application/provenance+xml",
        .extensions = &.{ "provx" },
    },
    .{
        .type = "application/pskc+xml",
        .extensions = &.{ "pskcxml" },
    },
    .{
        .type = "application/raml+yaml",
        .extensions = &.{ "raml" },
    },
    .{
        .type = "application/rdf+xml",
        .extensions = &.{ "rdf", "owl" },
    },
    .{
        .type = "application/reginfo+xml",
        .extensions = &.{ "rif" },
    },
    .{
        .type = "application/relax-ng-compact-syntax",
        .extensions = &.{ "rnc" },
    },
    .{
        .type = "application/resource-lists+xml",
        .extensions = &.{ "rl" },
    },
    .{
        .type = "application/resource-lists-diff+xml",
        .extensions = &.{ "rld" },
    },
    .{
        .type = "application/rls-services+xml",
        .extensions = &.{ "rs" },
    },
    .{
        .type = "application/route-apd+xml",
        .extensions = &.{ "rapd" },
    },
    .{
        .type = "application/route-s-tsid+xml",
        .extensions = &.{ "sls" },
    },
    .{
        .type = "application/route-usd+xml",
        .extensions = &.{ "rusd" },
    },
    .{
        .type = "application/rpki-ghostbusters",
        .extensions = &.{ "gbr" },
    },
    .{
        .type = "application/rpki-manifest",
        .extensions = &.{ "mft" },
    },
    .{
        .type = "application/rpki-roa",
        .extensions = &.{ "roa" },
    },
    .{
        .type = "application/rsd+xml",
        .extensions = &.{ "rsd" },
    },
    .{
        .type = "application/rss+xml",
        .extensions = &.{ "rss" },
    },
    .{
        .type = "application/rtf",
        .extensions = &.{ "rtf" },
    },
    .{
        .type = "application/sbml+xml",
        .extensions = &.{ "sbml" },
    },
    .{
        .type = "application/scvp-cv-request",
        .extensions = &.{ "scq" },
    },
    .{
        .type = "application/scvp-cv-response",
        .extensions = &.{ "scs" },
    },
    .{
        .type = "application/scvp-vp-request",
        .extensions = &.{ "spq" },
    },
    .{
        .type = "application/scvp-vp-response",
        .extensions = &.{ "spp" },
    },
    .{
        .type = "application/sdp",
        .extensions = &.{ "sdp" },
    },
    .{
        .type = "application/senml+xml",
        .extensions = &.{ "senmlx" },
    },
    .{
        .type = "application/sensml+xml",
        .extensions = &.{ "sensmlx" },
    },
    .{
        .type = "application/set-payment-initiation",
        .extensions = &.{ "setpay" },
    },
    .{
        .type = "application/set-registration-initiation",
        .extensions = &.{ "setreg" },
    },
    .{
        .type = "application/shf+xml",
        .extensions = &.{ "shf" },
    },
    .{
        .type = "application/sieve",
        .extensions = &.{ "siv", "sieve" },
    },
    .{
        .type = "application/smil+xml",
        .extensions = &.{ "smi", "smil" },
    },
    .{
        .type = "application/sparql-query",
        .extensions = &.{ "rq" },
    },
    .{
        .type = "application/sparql-results+xml",
        .extensions = &.{ "srx" },
    },
    .{
        .type = "application/sql",
        .extensions = &.{ "sql" },
    },
    .{
        .type = "application/srgs",
        .extensions = &.{ "gram" },
    },
    .{
        .type = "application/srgs+xml",
        .extensions = &.{ "grxml" },
    },
    .{
        .type = "application/sru+xml",
        .extensions = &.{ "sru" },
    },
    .{
        .type = "application/ssdl+xml",
        .extensions = &.{ "ssdl" },
    },
    .{
        .type = "application/ssml+xml",
        .extensions = &.{ "ssml" },
    },
    .{
        .type = "application/swid+xml",
        .extensions = &.{ "swidtag" },
    },
    .{
        .type = "application/tei+xml",
        .extensions = &.{ "tei", "teicorpus" },
    },
    .{
        .type = "application/thraud+xml",
        .extensions = &.{ "tfi" },
    },
    .{
        .type = "application/timestamped-data",
        .extensions = &.{ "tsd" },
    },
    .{
        .type = "application/toml",
        .extensions = &.{ "toml" },
    },
    .{
        .type = "application/trig",
        .extensions = &.{ "trig" },
    },
    .{
        .type = "application/ttml+xml",
        .extensions = &.{ "ttml" },
    },
    .{
        .type = "application/ubjson",
        .extensions = &.{ "ubj" },
    },
    .{
        .type = "application/urc-ressheet+xml",
        .extensions = &.{ "rsheet" },
    },
    .{
        .type = "application/urc-targetdesc+xml",
        .extensions = &.{ "td" },
    },
    .{
        .type = "application/voicexml+xml",
        .extensions = &.{ "vxml" },
    },
    .{
        .type = "application/wasm",
        .extensions = &.{ "wasm" },
    },
    .{
        .type = "application/watcherinfo+xml",
        .extensions = &.{ "wif" },
    },
    .{
        .type = "application/widget",
        .extensions = &.{ "wgt" },
    },
    .{
        .type = "application/winhlp",
        .extensions = &.{ "hlp" },
    },
    .{
        .type = "application/wsdl+xml",
        .extensions = &.{ "wsdl" },
    },
    .{
        .type = "application/wspolicy+xml",
        .extensions = &.{ "wspolicy" },
    },
    .{
        .type = "application/xaml+xml",
        .extensions = &.{ "xaml" },
    },
    .{
        .type = "application/xcap-att+xml",
        .extensions = &.{ "xav" },
    },
    .{
        .type = "application/xcap-caps+xml",
        .extensions = &.{ "xca" },
    },
    .{
        .type = "application/xcap-diff+xml",
        .extensions = &.{ "xdf" },
    },
    .{
        .type = "application/xcap-el+xml",
        .extensions = &.{ "xel" },
    },
    .{
        .type = "application/xcap-ns+xml",
        .extensions = &.{ "xns" },
    },
    .{
        .type = "application/xenc+xml",
        .extensions = &.{ "xenc" },
    },
    .{
        .type = "application/xfdf",
        .extensions = &.{ "xfdf" },
    },
    .{
        .type = "application/xhtml+xml",
        .extensions = &.{ "xhtml", "xht" },
    },
    .{
        .type = "application/xliff+xml",
        .extensions = &.{ "xlf" },
    },
    .{
        .type = "application/xml",
        .extensions = &.{ "xml", "xsl", "xsd", "rng" },
    },
    .{
        .type = "application/xml-dtd",
        .extensions = &.{ "dtd" },
    },
    .{
        .type = "application/xop+xml",
        .extensions = &.{ "xop" },
    },
    .{
        .type = "application/xproc+xml",
        .extensions = &.{ "xpl" },
    },
    .{
        .type = "application/xslt+xml",
        .extensions = &.{ "*xsl", "xslt" },
    },
    .{
        .type = "application/xspf+xml",
        .extensions = &.{ "xspf" },
    },
    .{
        .type = "application/xv+xml",
        .extensions = &.{ "mxml", "xhvml", "xvml", "xvm" },
    },
    .{
        .type = "application/yang",
        .extensions = &.{ "yang" },
    },
    .{
        .type = "application/yin+xml",
        .extensions = &.{ "yin" },
    },
    .{
        .type = "application/zip",
        .extensions = &.{ "zip" },
    },
    .{
        .type = "application/zip+dotlottie",
        .extensions = &.{ "lottie" },
    },
    .{
        .type = "audio/3gpp",
        .extensions = &.{ "*3gpp" },
    },
    .{
        .type = "audio/aac",
        .extensions = &.{ "adts", "aac" },
    },
    .{
        .type = "audio/adpcm",
        .extensions = &.{ "adp" },
    },
    .{
        .type = "audio/amr",
        .extensions = &.{ "amr" },
    },
    .{
        .type = "audio/basic",
        .extensions = &.{ "au", "snd" },
    },
    .{
        .type = "audio/midi",
        .extensions = &.{ "mid", "midi", "kar", "rmi" },
    },
    .{
        .type = "audio/mobile-xmf",
        .extensions = &.{ "mxmf" },
    },
    .{
        .type = "audio/mp3",
        .extensions = &.{ "*mp3" },
    },
    .{
        .type = "audio/mp4",
        .extensions = &.{ "m4a", "mp4a", "m4b" },
    },
    .{
        .type = "audio/mpeg",
        .extensions = &.{ "mpga", "mp2", "mp2a", "mp3", "m2a", "m3a" },
    },
    .{
        .type = "audio/ogg",
        .extensions = &.{ "oga", "ogg", "spx", "opus" },
    },
    .{
        .type = "audio/s3m",
        .extensions = &.{ "s3m" },
    },
    .{
        .type = "audio/silk",
        .extensions = &.{ "sil" },
    },
    .{
        .type = "audio/wav",
        .extensions = &.{ "wav" },
    },
    .{
        .type = "audio/wave",
        .extensions = &.{ "*wav" },
    },
    .{
        .type = "audio/webm",
        .extensions = &.{ "weba" },
    },
    .{
        .type = "audio/xm",
        .extensions = &.{ "xm" },
    },
    .{
        .type = "font/collection",
        .extensions = &.{ "ttc" },
    },
    .{
        .type = "font/otf",
        .extensions = &.{ "otf" },
    },
    .{
        .type = "font/ttf",
        .extensions = &.{ "ttf" },
    },
    .{
        .type = "font/woff",
        .extensions = &.{ "woff" },
    },
    .{
        .type = "font/woff2",
        .extensions = &.{ "woff2" },
    },
    .{
        .type = "image/aces",
        .extensions = &.{ "exr" },
    },
    .{
        .type = "image/apng",
        .extensions = &.{ "apng" },
    },
    .{
        .type = "image/avci",
        .extensions = &.{ "avci" },
    },
    .{
        .type = "image/avcs",
        .extensions = &.{ "avcs" },
    },
    .{
        .type = "image/avif",
        .extensions = &.{ "avif" },
    },
    .{
        .type = "image/bmp",
        .extensions = &.{ "bmp", "dib" },
    },
    .{
        .type = "image/cgm",
        .extensions = &.{ "cgm" },
    },
    .{
        .type = "image/dicom-rle",
        .extensions = &.{ "drle" },
    },
    .{
        .type = "image/dpx",
        .extensions = &.{ "dpx" },
    },
    .{
        .type = "image/emf",
        .extensions = &.{ "emf" },
    },
    .{
        .type = "image/fits",
        .extensions = &.{ "fits" },
    },
    .{
        .type = "image/g3fax",
        .extensions = &.{ "g3" },
    },
    .{
        .type = "image/gif",
        .extensions = &.{ "gif" },
    },
    .{
        .type = "image/heic",
        .extensions = &.{ "heic" },
    },
    .{
        .type = "image/heic-sequence",
        .extensions = &.{ "heics" },
    },
    .{
        .type = "image/heif",
        .extensions = &.{ "heif" },
    },
    .{
        .type = "image/heif-sequence",
        .extensions = &.{ "heifs" },
    },
    .{
        .type = "image/hej2k",
        .extensions = &.{ "hej2" },
    },
    .{
        .type = "image/ief",
        .extensions = &.{ "ief" },
    },
    .{
        .type = "image/jaii",
        .extensions = &.{ "jaii" },
    },
    .{
        .type = "image/jais",
        .extensions = &.{ "jais" },
    },
    .{
        .type = "image/jls",
        .extensions = &.{ "jls" },
    },
    .{
        .type = "image/jp2",
        .extensions = &.{ "jp2", "jpg2" },
    },
    .{
        .type = "image/jpeg",
        .extensions = &.{ "jpg", "jpeg", "jpe" },
    },
    .{
        .type = "image/jph",
        .extensions = &.{ "jph" },
    },
    .{
        .type = "image/jphc",
        .extensions = &.{ "jhc" },
    },
    .{
        .type = "image/jpm",
        .extensions = &.{ "jpm", "jpgm" },
    },
    .{
        .type = "image/jpx",
        .extensions = &.{ "jpx", "jpf" },
    },
    .{
        .type = "image/jxl",
        .extensions = &.{ "jxl" },
    },
    .{
        .type = "image/jxr",
        .extensions = &.{ "jxr" },
    },
    .{
        .type = "image/jxra",
        .extensions = &.{ "jxra" },
    },
    .{
        .type = "image/jxrs",
        .extensions = &.{ "jxrs" },
    },
    .{
        .type = "image/jxs",
        .extensions = &.{ "jxs" },
    },
    .{
        .type = "image/jxsc",
        .extensions = &.{ "jxsc" },
    },
    .{
        .type = "image/jxsi",
        .extensions = &.{ "jxsi" },
    },
    .{
        .type = "image/jxss",
        .extensions = &.{ "jxss" },
    },
    .{
        .type = "image/ktx",
        .extensions = &.{ "ktx" },
    },
    .{
        .type = "image/ktx2",
        .extensions = &.{ "ktx2" },
    },
    .{
        .type = "image/pjpeg",
        .extensions = &.{ "jfif" },
    },
    .{
        .type = "image/png",
        .extensions = &.{ "png" },
    },
    .{
        .type = "image/sgi",
        .extensions = &.{ "sgi" },
    },
    .{
        .type = "image/svg+xml",
        .extensions = &.{ "svg", "svgz" },
    },
    .{
        .type = "image/t38",
        .extensions = &.{ "t38" },
    },
    .{
        .type = "image/tiff",
        .extensions = &.{ "tif", "tiff" },
    },
    .{
        .type = "image/tiff-fx",
        .extensions = &.{ "tfx" },
    },
    .{
        .type = "image/webp",
        .extensions = &.{ "webp" },
    },
    .{
        .type = "image/wmf",
        .extensions = &.{ "wmf" },
    },
    .{
        .type = "message/disposition-notification",
        .extensions = &.{ "disposition-notification" },
    },
    .{
        .type = "message/global",
        .extensions = &.{ "u8msg" },
    },
    .{
        .type = "message/global-delivery-status",
        .extensions = &.{ "u8dsn" },
    },
    .{
        .type = "message/global-disposition-notification",
        .extensions = &.{ "u8mdn" },
    },
    .{
        .type = "message/global-headers",
        .extensions = &.{ "u8hdr" },
    },
    .{
        .type = "message/rfc822",
        .extensions = &.{ "eml", "mime", "mht", "mhtml" },
    },
    .{
        .type = "model/3mf",
        .extensions = &.{ "3mf" },
    },
    .{
        .type = "model/gltf+json",
        .extensions = &.{ "gltf" },
    },
    .{
        .type = "model/gltf-binary",
        .extensions = &.{ "glb" },
    },
    .{
        .type = "model/iges",
        .extensions = &.{ "igs", "iges" },
    },
    .{
        .type = "model/jt",
        .extensions = &.{ "jt" },
    },
    .{
        .type = "model/mesh",
        .extensions = &.{ "msh", "mesh", "silo" },
    },
    .{
        .type = "model/mtl",
        .extensions = &.{ "mtl" },
    },
    .{
        .type = "model/obj",
        .extensions = &.{ "obj" },
    },
    .{
        .type = "model/prc",
        .extensions = &.{ "prc" },
    },
    .{
        .type = "model/step",
        .extensions = &.{ "step", "stp", "stpnc", "p21", "210" },
    },
    .{
        .type = "model/step+xml",
        .extensions = &.{ "stpx" },
    },
    .{
        .type = "model/step+zip",
        .extensions = &.{ "stpz" },
    },
    .{
        .type = "model/step-xml+zip",
        .extensions = &.{ "stpxz" },
    },
    .{
        .type = "model/stl",
        .extensions = &.{ "stl" },
    },
    .{
        .type = "model/u3d",
        .extensions = &.{ "u3d" },
    },
    .{
        .type = "model/vrml",
        .extensions = &.{ "wrl", "vrml" },
    },
    .{
        .type = "model/x3d+binary",
        .extensions = &.{ "*x3db", "x3dbz" },
    },
    .{
        .type = "model/x3d+fastinfoset",
        .extensions = &.{ "x3db" },
    },
    .{
        .type = "model/x3d+vrml",
        .extensions = &.{ "*x3dv", "x3dvz" },
    },
    .{
        .type = "model/x3d+xml",
        .extensions = &.{ "x3d", "x3dz" },
    },
    .{
        .type = "model/x3d-vrml",
        .extensions = &.{ "x3dv" },
    },
    .{
        .type = "text/cache-manifest",
        .extensions = &.{ "appcache", "manifest" },
    },
    .{
        .type = "text/calendar",
        .extensions = &.{ "ics", "ifb" },
    },
    .{
        .type = "text/coffeescript",
        .extensions = &.{ "coffee", "litcoffee" },
    },
    .{
        .type = "text/css",
        .extensions = &.{ "css" },
    },
    .{
        .type = "text/csv",
        .extensions = &.{ "csv" },
    },
    .{
        .type = "text/html",
        .extensions = &.{ "html", "htm", "shtml" },
    },
    .{
        .type = "text/jade",
        .extensions = &.{ "jade" },
    },
    .{
        .type = "text/javascript",
        .extensions = &.{ "js", "mjs" },
    },
    .{
        .type = "text/jsx",
        .extensions = &.{ "jsx" },
    },
    .{
        .type = "text/less",
        .extensions = &.{ "less" },
    },
    .{
        .type = "text/markdown",
        .extensions = &.{ "md", "markdown" },
    },
    .{
        .type = "text/mathml",
        .extensions = &.{ "mml" },
    },
    .{
        .type = "text/mdx",
        .extensions = &.{ "mdx" },
    },
    .{
        .type = "text/n3",
        .extensions = &.{ "n3" },
    },
    .{
        .type = "text/plain",
        .extensions = &.{ "txt", "text", "conf", "def", "list", "log", "in", "ini" },
    },
    .{
        .type = "text/richtext",
        .extensions = &.{ "rtx" },
    },
    .{
        .type = "text/rtf",
        .extensions = &.{ "*rtf" },
    },
    .{
        .type = "text/sgml",
        .extensions = &.{ "sgml", "sgm" },
    },
    .{
        .type = "text/shex",
        .extensions = &.{ "shex" },
    },
    .{
        .type = "text/slim",
        .extensions = &.{ "slim", "slm" },
    },
    .{
        .type = "text/spdx",
        .extensions = &.{ "spdx" },
    },
    .{
        .type = "text/stylus",
        .extensions = &.{ "stylus", "styl" },
    },
    .{
        .type = "text/tab-separated-values",
        .extensions = &.{ "tsv" },
    },
    .{
        .type = "text/troff",
        .extensions = &.{ "t", "tr", "roff", "man", "me", "ms" },
    },
    .{
        .type = "text/turtle",
        .extensions = &.{ "ttl" },
    },
    .{
        .type = "text/uri-list",
        .extensions = &.{ "uri", "uris", "urls" },
    },
    .{
        .type = "text/vcard",
        .extensions = &.{ "vcard" },
    },
    .{
        .type = "text/vtt",
        .extensions = &.{ "vtt" },
    },
    .{
        .type = "text/wgsl",
        .extensions = &.{ "wgsl" },
    },
    .{
        .type = "text/xml",
        .extensions = &.{ "*xml" },
    },
    .{
        .type = "text/yaml",
        .extensions = &.{ "yaml", "yml" },
    },
    .{
        .type = "video/3gpp",
        .extensions = &.{ "3gp", "3gpp" },
    },
    .{
        .type = "video/3gpp2",
        .extensions = &.{ "3g2" },
    },
    .{
        .type = "video/h261",
        .extensions = &.{ "h261" },
    },
    .{
        .type = "video/h263",
        .extensions = &.{ "h263" },
    },
    .{
        .type = "video/h264",
        .extensions = &.{ "h264" },
    },
    .{
        .type = "video/iso.segment",
        .extensions = &.{ "m4s" },
    },
    .{
        .type = "video/jpeg",
        .extensions = &.{ "jpgv" },
    },
    .{
        .type = "video/jpm",
        .extensions = &.{ "*jpm", "*jpgm" },
    },
    .{
        .type = "video/mj2",
        .extensions = &.{ "mj2", "mjp2" },
    },
    .{
        .type = "video/mp2t",
        .extensions = &.{ "ts", "m2t", "m2ts", "mts" },
    },
    .{
        .type = "video/mp4",
        .extensions = &.{ "mp4", "mp4v", "mpg4" },
    },
    .{
        .type = "video/mpeg",
        .extensions = &.{ "mpeg", "mpg", "mpe", "m1v", "m2v" },
    },
    .{
        .type = "video/ogg",
        .extensions = &.{ "ogv" },
    },
    .{
        .type = "video/quicktime",
        .extensions = &.{ "qt", "mov" },
    },
    .{
        .type = "video/webm",
        .extensions = &.{ "webm" },
    },
};
