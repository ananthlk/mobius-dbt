#!/usr/bin/env python3
"""
Download FL AHCA Medicaid PML (prw19000) and/or PPL (prd19100) files.

The Florida Medicaid portal (Registration | linkid=pml) hosts public "Current Versions"
links to static files — no login required for those. Two formats are offered:
  - Spreadsheet: prw19000.zip (PML), prd19100.zip (PPL) — we use these; ZIP contains CSV/Excel.
  - Pipe-delimited: prw19002.zip (PML), prd19102.zip (PPL) — alternative format.

When the portal is accessible, we fetch the page, extract links by filename (prw19000,
prd19100) or .zip/.csv, download ZIPs, extract the contained CSV/file to the output path.
When the portal requires login or is unavailable, use --pml-path / --ppl-path with
pre-downloaded files.

Usage:
  uv run python scripts/download_ahca_medicaid.py --pml -o ./data
  uv run python scripts/download_ahca_medicaid.py --ppl -o ./data
  uv run python scripts/download_ahca_medicaid.py --pml --ppl -o ./data
  uv run python scripts/download_ahca_medicaid.py --pml-path /path/to/prw19000.csv -o ./data
  uv run python scripts/download_ahca_medicaid.py --ppl-path /path/to/prd19100.csv -o ./data
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import zipfile
from pathlib import Path
from urllib.parse import urljoin, urlparse, quote
from urllib.request import Request, urlopen

# Registration page that lists PML/PPL "Current Versions" (public, no login). Directory URL redirects to Page Not Found.
# https://portal.flmmis.com/FLPublic/Provider_ManagedCare/Provider_ManagedCare_Registration/tabId/77/Default.aspx?linkid=pml
DEFAULT_PORTAL_URL = "https://portal.flmmis.com/FLPublic/Provider_ManagedCare/Provider_ManagedCare_Registration/tabId/77/Default.aspx?linkid=pml"
USER_AGENT = "Mobius-MedicaidDownload/1.0"


def _extract_csv_links(html: str, base_url: str) -> list[str]:
    """Extract absolute URLs for PML/PPL: .csv, .zip, or path containing prw19000/prd19100/prw19002/prd19102."""
    pattern = re.compile(r'href\s*=\s*["\']([^"\']+)["\']', re.IGNORECASE)
    seen = set()
    result = []
    for match in pattern.finditer(html):
        href = match.group(1).strip()
        if not href or href.startswith("#") or href.startswith("mailto:") or href.startswith("javascript:"):
            continue
        absolute = urljoin(base_url, href)
        path_lower = (urlparse(absolute).path or "").lower()
        if (
            path_lower.endswith(".csv")
            or path_lower.endswith(".zip")
            or "prw19000" in path_lower
            or "prd19100" in path_lower
            or "prw19002" in path_lower
            or "prd19102" in path_lower
        ):
            if absolute not in seen:
                seen.add(absolute)
                result.append(absolute)
    return result


def _fetch_page(url: str, timeout: float = 30.0) -> str:
    req = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"})
    with urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def _normalize_download_url(url: str) -> str:
    """Encode path so spaces/special chars are valid (e.g. 'Managed Care' -> %20)."""
    parsed = urlparse(url)
    path = parsed.path or ""
    if path and (" " in path or not path.isascii()):
        path = quote(path, safe="/:")
    return parsed._replace(path=path).geturl()


def _download_to(url: str, dest: Path, timeout: float = 60.0) -> bool:
    """Download url to dest. Returns True on success."""
    url = _normalize_download_url(url)
    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=timeout) as resp:
            dest.parent.mkdir(parents=True, exist_ok=True)
            with open(dest, "wb") as f:
                shutil.copyfileobj(resp, f)
        return True
    except Exception as e:
        print(f"  Download failed {url}: {e}", file=sys.stderr)
        return False


def _download_zip_and_extract(url: str, output_dir: Path, want_csv_name: str, timeout: float = 60.0) -> Path | None:
    """Download a .zip URL, extract contents, and return path to the extracted CSV/file.
    Prefers a member named like want_csv_name (e.g. prw19000.csv); otherwise first .csv or single file.
    """
    path_lower = (urlparse(url).path or "").lower()
    zip_name = Path(path_lower).name or "download.zip"
    zip_dest = output_dir / zip_name
    if not _download_to(url, zip_dest, timeout=timeout):
        return None
    try:
        with zipfile.ZipFile(zip_dest, "r") as zf:
            names = zf.namelist()
            # Prefer exact match, then any .csv, then first file
            candidate = None
            for n in names:
                if n.endswith("/"):
                    continue
                base = Path(n).name.lower()
                if base == want_csv_name.lower():
                    candidate = n
                    break
                if candidate is None and (base.endswith(".csv") or base.endswith(".txt")):
                    candidate = n
            if candidate is None and names:
                candidate = next((n for n in names if not n.endswith("/")), None)
            if not candidate:
                return None
            zf.extract(candidate, output_dir)
            extracted = output_dir / candidate
            # Normalize to desired name so downstream expects prw19000.csv / prd19100.csv
            final = output_dir / want_csv_name
            if extracted != final:
                if final.exists():
                    final.unlink()
                shutil.move(str(extracted), str(final))
            zip_dest.unlink(missing_ok=True)
            return final
    except Exception as e:
        print(f"  Extract failed {zip_dest}: {e}", file=sys.stderr)
        zip_dest.unlink(missing_ok=True)
        return None


def _infer_filename(url: str, want_pml: bool, want_ppl: bool) -> str:
    path = (urlparse(url).path or "").lower()
    if "prd19100" in path:
        return "prd19100.csv"
    if "prw19000" in path:
        return "prw19000.csv"
    if path.endswith(".csv"):
        return Path(path).name or "download.csv"
    return "prw19000.csv" if want_pml else "prd19100.csv"


# Emission prefix for progress (callers can filter stdout by this to show user-facing messages)
EMIT_PREFIX = "[EMIT] "


def download_from_portal(portal_url: str, output_dir: Path, want_pml: bool, want_ppl: bool) -> dict[str, str | None]:
    """
    Fetch portal page, find CSV links, download PML and/or PPL to output_dir.
    Returns dict with keys pml_path, ppl_path (paths as string or None if not found).
    """
    result = {"pml_path": None, "ppl_path": None}
    print(f"{EMIT_PREFIX}Scraping portal for PML and PPL...", flush=True)
    try:
        html = _fetch_page(portal_url)
    except Exception as e:
        print(f"Could not fetch portal {portal_url}: {e}", file=sys.stderr)
        return result
    links = _extract_csv_links(html, portal_url)
    # Prefer spreadsheet (prw19000/prd19100) over pipe-delimited (prw19002/prd19102) — our cleanse expects spreadsheet columns
    def pml_order(u: str) -> int:
        p = (urlparse(u).path or "").lower()
        if "prw19000" in p and "prw19002" not in p:
            return 0
        return 1

    def ppl_order(u: str) -> int:
        p = (urlparse(u).path or "").lower()
        if "prd19100" in p and "prd19102" not in p:
            return 0
        return 1

    links.sort(key=lambda u: (pml_order(u), ppl_order(u)))
    for url in links:
        path_lower = (urlparse(url).path or "").lower()
        is_pml = "prw19000" in path_lower or "prw19002" in path_lower or (want_pml and result["pml_path"] is None and "pml" in path_lower)
        is_ppl = "prd19100" in path_lower or "prd19102" in path_lower or (want_ppl and result["ppl_path"] is None and "ppl" in path_lower)
        if not is_pml and not is_ppl:
            if path_lower.endswith((".csv", ".zip")) and want_pml and result["pml_path"] is None:
                is_pml = True
            elif path_lower.endswith((".csv", ".zip")) and want_ppl and result["ppl_path"] is None:
                is_ppl = True
        if is_pml and want_pml and result["pml_path"] is None:
            # Portal serves .zip (spreadsheet prw19000.zip or pipe-delimited prw19002.zip); extract to prw19000.csv
            if path_lower.endswith(".zip"):
                dest = _download_zip_and_extract(url, output_dir, "prw19000.csv")
                if dest:
                    result["pml_path"] = str(dest)
                    print(f"{EMIT_PREFIX}Downloaded PML.", flush=True)
                    print(f"  Downloaded and extracted PML to {dest}")
            else:
                fname = "prw19000.csv" if "prw19000" in path_lower else "pml.csv"
                dest = output_dir / fname
                if _download_to(url, dest):
                    result["pml_path"] = str(dest)
                    print(f"{EMIT_PREFIX}Downloaded PML.", flush=True)
                    print(f"  Downloaded PML to {dest}")
        if is_ppl and want_ppl and result["ppl_path"] is None:
            if path_lower.endswith(".zip"):
                dest = _download_zip_and_extract(url, output_dir, "prd19100.csv")
                if dest:
                    result["ppl_path"] = str(dest)
                    print(f"{EMIT_PREFIX}Downloaded PPL.", flush=True)
                    print(f"  Downloaded and extracted PPL to {dest}")
            else:
                fname = "prd19100.csv" if "prd19100" in path_lower else "ppl.csv"
                dest = output_dir / fname
                if _download_to(url, dest):
                    result["ppl_path"] = str(dest)
                    print(f"{EMIT_PREFIX}Downloaded PPL.", flush=True)
                    print(f"  Downloaded PPL to {dest}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Download FL AHCA Medicaid PML/PPL files.")
    parser.add_argument("--pml", action="store_true", help="Attempt to download PML (prw19000)")
    parser.add_argument("--ppl", action="store_true", help="Attempt to download PPL (prd19100)")
    parser.add_argument("--pml-path", type=Path, metavar="PATH", help="Use pre-downloaded PML file (copy to -o)")
    parser.add_argument("--ppl-path", type=Path, metavar="PATH", help="Use pre-downloaded PPL file (copy to -o)")
    parser.add_argument("-o", "--output", type=Path, default=Path("."), help="Output directory or file (default: .)")
    parser.add_argument("--portal-url", type=str, default=DEFAULT_PORTAL_URL, help="Portal page URL to scrape for links")
    args = parser.parse_args()

    if not args.pml and not args.ppl and not args.pml_path and not args.ppl_path:
        parser.error("Specify at least one of: --pml, --ppl, --pml-path, --ppl-path")

    out = args.output
    if out.suffix.lower() == ".csv":
        output_dir = out.parent
        single_file = out
    else:
        output_dir = out
        single_file = None

    output_dir = output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    pml_dest = None
    ppl_dest = None

    if args.pml_path:
        if not args.pml_path.exists():
            print(f"PML path not found: {args.pml_path}", file=sys.stderr)
            return 1
        print(f"{EMIT_PREFIX}Using pre-downloaded PML; copying to output.", flush=True)
        pml_dest = (single_file if single_file and not args.ppl and not args.ppl_path else output_dir / "prw19000.csv")
        shutil.copy2(args.pml_path, pml_dest)
        print(f"  Copied PML to {pml_dest}")
    elif args.pml:
        result = download_from_portal(args.portal_url, output_dir, want_pml=True, want_ppl=False)
        if result.get("pml_path"):
            pml_dest = Path(result["pml_path"])
        else:
            print("  No PML link found on portal. Use --pml-path with a pre-downloaded file.", file=sys.stderr)

    if args.ppl_path:
        if not args.ppl_path.exists():
            print(f"PPL path not found: {args.ppl_path}", file=sys.stderr)
            return 1
        print(f"{EMIT_PREFIX}Using pre-downloaded PPL; copying to output.", flush=True)
        ppl_dest = (single_file if single_file and not args.pml and not args.pml_path else output_dir / "prd19100.csv")
        shutil.copy2(args.ppl_path, ppl_dest)
        print(f"  Copied PPL to {ppl_dest}")
    elif args.ppl:
        result = download_from_portal(args.portal_url, output_dir, want_pml=False, want_ppl=True)
        if result.get("ppl_path"):
            ppl_dest = Path(result["ppl_path"])
        else:
            print("  No PPL link found on portal. Use --ppl-path with a pre-downloaded file.", file=sys.stderr)

    if args.pml and args.ppl and (not pml_dest or not ppl_dest):
        both = download_from_portal(args.portal_url, output_dir, want_pml=True, want_ppl=True)
        if not pml_dest and both.get("pml_path"):
            pml_dest = Path(both["pml_path"])
        if not ppl_dest and both.get("ppl_path"):
            ppl_dest = Path(both["ppl_path"])

    if pml_dest:
        print(f"PML: {pml_dest}")
    if ppl_dest:
        print(f"PPL: {ppl_dest}")
    return 0 if (pml_dest or ppl_dest) else 1


if __name__ == "__main__":
    sys.exit(main())
