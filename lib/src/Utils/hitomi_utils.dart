// Code adapted and derived from Heliotrope
// https://github.com/Saebasol/Heliotrope
// Huge thanks to the relevant parties because this is a nightmare.


// Implementation of the GG functions.
class GG {
    final RegExp exp = RegExp(r"(..)(.)$");

    String code;
    List<int> caseList = [];
    int defaultO = 0;
    int inCaseO = 0;
    String b = "";

    GG(this.code);

    void parse() {
        final List<String> lines = code.split("\n");
        for (final String line in lines) {
            if (line.startsWith("var o = ") && line.endsWith(";")) {
                defaultO = int.parse(line.substring(8, line.length - 1));
            }

            if (line.startsWith("o = ") && line.endsWith("; break;")) {
                inCaseO = int.parse(line.substring(4, line.length - 8));
            }

            if (line.startsWith("case ")) {
                final String matchedInt = line.substring(5, line.length - 1);
                caseList.add(int.parse(matchedInt));
            }

            if (line.startsWith("b: ")) {
                b = line.substring(4, line.length - 1);
            }
        }
    }

    void refresh(String code) {
        this.code = code;
        caseList.clear();
        parse();
    }

    int m(int g) {
        if (caseList.contains(g)) {
            return inCaseO;
        }

        return defaultO;
    }

    String s(String h) {
        final RegExpMatch? match = exp.firstMatch(h);

        if (match == null) {
            throw ArgumentError.value(h, "h", "Invalid hash format.");
        }

        final String m2 = match.group(2)!;
        final String m1 = match.group(1)!;

        return BigInt.parse(m2 + m1, radix: 16).toString();
    }
}

class HitomiFile {
    final int galleryInfoID;
    final String name;
    final int width;
    final int height;
    final String hash;
    final int hasWebp;
    final int hasAvif;
    final int? hasAvifSmallTn;

    HitomiFile({
        required this.galleryInfoID,
        required this.name,
        required this.width,
        required this.height,
        required this.hash,
        required this.hasWebp,
        required this.hasAvif,
        this.hasAvifSmallTn,
    });

    factory HitomiFile.fromJson(int galleryInfoID, Map<String, dynamic> jsonData) {
        return HitomiFile(
            galleryInfoID: galleryInfoID,
            name: jsonData['name'],
            width: jsonData['width'],
            height: jsonData['height'],
            hash: jsonData['hash'],
            hasWebp: jsonData['haswebp'] ?? 1,
            hasAvif: jsonData['hasavif'],
            hasAvifSmallTn: jsonData['hasavifsmalltn'],
        );
    }
}

// Implementation of the Common set of functions from common.js
class Common {
    final GG gg;
    // Constant from JavaScript.
    static const String domain2 = 'gold-usergeneratedcontent.net';
    final String domain = 'ltn.$domain2';
  
    Common(String code) : gg = GG(code)..parse();
          
  
    /// Returns a subdomain computed from [url], [base], and [dir].
    /// Replicates the JavaScript function subdomain_from_url.
    String subdomainFromUrl(String url, String? base, String dir) {
        String retval = '';
        // In JS: if (!base) { ... }
        if (base == null || base.isEmpty) {
            if (dir == 'webp') {
                retval = 'w';
            } else if (dir == 'avif') {
                retval = 'a';
            }
        }
  
        // Using radix 16.
        final int b = 16;
  
        // RegExp: /\/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])/
        final regExp = RegExp(r'\/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])');
        final match = regExp.firstMatch(url);
        if (match == null) {
            //print("retval1: $retval");
            return retval;
        }
  
        // Note: JavaScript concatenates m[2]+m[1]
        final hexPair = match.group(2)! + match.group(1)!;
        final g = int.tryParse(hexPair, radix: b);
        // Check against NaN.
        if (g != null) {
            if (base != null && base.isNotEmpty) {
                // Use gg.m(g) to determine a character offset.
                retval = String.fromCharCode(97 + gg.m(g)) + base;
            } else {
                retval = retval + (1 + gg.m(g)).toString();
            }
        }

        //print("retval2: $retval");
        return retval;
    }
  
    /// Returns a new URL by replacing the hostname in [url] with a computed subdomain.
    /// Replicates the JavaScript function url_from_url.
    String urlFromUrl(String url, String? base, String dir) {
        // The regular expression looks for the host portion with either hitomi.la or gold-usergeneratedcontent.net.
        final regExp = RegExp(r'\/\/..?\.(?:gold-usergeneratedcontent\.net|hitomi\.la)\/');
        final replacement = '//${subdomainFromUrl(url, base, dir)}.$domain2/';
        return url.replaceFirst(regExp, replacement);
    }
  
    /// Computes the full path from a given hash.
    /// Mirrors full_path_from_hash(hash) => gg.b+gg.s(hash)+'/'+hash.
    String fullPathFromHash(String hash) {
        return  '${gg.b + gg.s(hash)}/$hash';
    }
  
    /// Computes a “real” full path from the hash.
    /// Mirrors real_full_path_from_hash(hash).
    String realFullPathFromHash(String hash) {
        // JavaScript equivalent: hash.replace(/^.*(..)(.)$/, '$2/$1/'+hash);
        final regExp = RegExp(r'^.*(..)(.)$');
        final match = regExp.firstMatch(hash);
        if (match != null) {
            return match.group(2)! + r'/' + match.group(1)! + r'/' + hash;
        }
        return hash;
    }
  
    /// Constructs a URL from a gallery hash.
    /// Mirrors url_from_hash(galleryid, image, dir, ext)
    String urlFromHash(String galleryId, HitomiFile image, String dir, [String? ext]) {
        // Determine extension: ext || dir || image.name.split('.').pop();
        String computedExt;
        if (ext != null && ext.isNotEmpty) {
            computedExt = ext;
        } else if (dir.isNotEmpty) {
            computedExt = dir;
        } else {
            // Assumes image.name is something like "foo.jpg".
            final parts = image.name.split('.');
            computedExt = parts.isNotEmpty ? parts.last : '';
        }
  
        // If the directory indicates a special image type, then don’t use it as folder.
        if (dir == 'webp' || dir == 'avif') {
            dir = '';
        } else if (dir.isNotEmpty) {
            dir = '$dir/';
        }
  
        return r'https://a.' + domain2 + r'/' + dir + fullPathFromHash(image.hash) + r'.' + computedExt;
    }
  
    /// Constructs a URL from a gallery hash and then processes it further.
    /// Mirrors url_from_url_from_hash(galleryid, image, dir, ext, base)
    String urlFromUrlFromHash(String galleryId, HitomiFile image, String dir, String ext, [String? base]) {
        if (base == 'tn') {
            // When base is 'tn' use the "real" full path.
            final url = r'https://a.' +
                domain2 +
                r'/' +
                dir +
                r'/' +
                realFullPathFromHash(image.hash) +
                r'.' +
                ext;
            return urlFromUrl(url, base, dir);
        }
        return urlFromUrl(urlFromHash(galleryId, image, dir, ext), base, dir);
    }
  
    /// Rewrites thumbnail paths in [html] by replacing the tn.hitomi.la URLs.
    /// Mirrors rewrite_tn_paths(html).
    String rewriteTnPaths(String html) {
        // Matches URLs like: //tn.hitomi.la/[^/]+/[0-9a-f]/[0-9a-f]{2}/[0-9a-f]{64}
        final regExp = RegExp(r'\/\/tn\.hitomi\.la\/[^\/]+\/[0-9a-f]\/[0-9a-f]{2}\/[0-9a-f]{64}');
        return html.replaceAllMapped(regExp, (match) {
            return urlFromUrl(match.group(0)!, 'tn', '');
        });
    }

    String getThumbnail(String galleryID, HitomiFile image) {
        return urlFromUrlFromHash(galleryID, image, "webpbigtn", "webp", "tn");
    }

    List<String> imageUrls(String galleryID, List<HitomiFile> images, {bool preferWebp = true}) {
        return images
            .map((image) => imageUrlFromImage(galleryID, image, preferWebp: preferWebp))
            .toList();
    }

    String imageUrlFromImage(String galleryID, HitomiFile image, {bool preferWebp = false}) {
        // Choose "avif" if available and not preferring webp; otherwise "webp".
        final String chosenDir = (image.hasAvif == 1 && !preferWebp) ? "avif" : "webp";
        return urlFromUrlFromHash(galleryID, image, chosenDir, "", "");
    }
}
