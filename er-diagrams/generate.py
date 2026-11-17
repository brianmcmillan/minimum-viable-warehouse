#!/usr/bin/env python3
"""Generate Mermaid ER diagrams for every solution in this repo.

    python3 er-diagrams/generate.py          # writes er-diagrams/mermaid/*.md
    python3 er-diagrams/generate.py --pdf    # also writes er-diagrams/pdf/*.pdf

The diagrams are read from each solution's built database (build/*.db and
archive/*.db), so run `make demo` in a solution first if its database is
missing or stale. Columns, types, primary keys and declared foreign keys
come from SQLite's own catalogue. Several models declare no foreign keys
on purpose; for those, the joins the model intends are listed in LOGICAL
below and drawn as dashed lines.

The Mermaid step needs only the Python standard library. The PDF step
also needs the Mermaid CLI (`mmdc`) and the `pypdf` package.
"""
import os, re, shutil, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---------------------------------------------------------------- catalogue
class Db:
    def __init__(self, path):
        self.con = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
    def tables(self):
        return [r[0] for r in self.con.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    def cols(self, t):      # cid, name, type, notnull, default, pk
        return self.con.execute('PRAGMA table_info("%s")' % t).fetchall()
    def fks(self, t):       # one entry per declared FK: (parent, [child cols])
        by_id = {}
        for fid, seq, parent, frm, to, *_ in self.con.execute(
                'PRAGMA foreign_key_list("%s")' % t):
            by_id.setdefault(fid, (parent, []))[1].append(frm)
        return list(by_id.values())

def is_stage(t):
    return t.startswith(("stg_", "source_landing")) or "_stg" in t
def is_meta(t):
    return (t.startswith(("meta_", "hook_")) or t.endswith("load_params")
            or t in ("load_guard", "dv_load_audit", "core_table",
                     "uss_refresh", "activity_catalog"))

# ------------------------------------------------------------------ mermaid
def ident(t, upper):
    name = t.upper() if upper else t
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
        return name, None
    return "T_" + re.sub(r"\W", "_", name).strip("_"), name      # alias

def entity(db, t, keys_only, upper):
    fkcols = {c for _, cs in db.fks(t) for c in cs}
    eid, alias = ident(t, upper)
    out = ["    %s%s {" % (eid, '["%s"]' % alias if alias else "")]
    for _, name, typ, _, _, pk in db.cols(t):
        k = [x for x, on in (("PK", pk > 0), ("FK", name in fkcols)) if on]
        if keys_only and not k:
            continue
        typ = re.sub(r"\s+", "_", typ.strip()) or "untyped"
        out.append("        %s %s%s" % (typ, name, " " + ", ".join(k) if k else ""))
    out.append("    }")
    return "\n".join(out)

def relations(db, tables, context, labels, logical, upper):
    out = []
    for t in tables:
        info = {c[1]: c for c in db.cols(t)}
        pk = [c[1] for c in db.cols(t) if c[5] > 0]
        for parent, cs in db.fks(t):
            if parent not in tables or (parent in context and t in context):
                continue
            required = all(info[c][3] or info[c][5] for c in cs)
            left = "||" if required else "|o"
            right = "o|" if pk == cs else "o{"
            label = labels.get((t, cs[0]), ", ".join(cs))
            out.append('    %s %s--%s %s : "%s"' % (
                ident(parent, upper)[0], left, right, ident(t, upper)[0], label))
    for parent, child, label in logical:
        if parent in tables and child in tables:
            out.append('    %s ||..o{ %s : "%s"' % (
                ident(parent, upper)[0], ident(child, upper)[0], label))
    return "\n".join(out)

def diagram(db, layer, sol):
    tables = [t for t in layer["tables"] if t in db.tables()]
    context = layer.get("context", [])
    upper = sol.get("upper", False)
    ents = [entity(db, t, layer.get("keys_only", False) or t in context, upper)
            for t in tables]
    rel = relations(db, tables, context, sol.get("labels", {}),
                    sol.get("logical", []), upper)
    return "erDiagram\n" + "\n".join(ents) + ("\n" + rel if rel else "")

# ---------------------------------------------------------------- solutions
ARCHIVE_TEXT = ("The durable raw layer, in its own database file. Every delivery "
                "is captured here verbatim before it is applied, and the tables "
                "are append-only.")

def default_layers(build, archive, core_title="Core model", core_text=""):
    """Core, then metadata, staging and the archive, each if non-empty."""
    tabs = build.tables()
    core = [t for t in tabs if not is_stage(t) and not is_meta(t)]
    meta = [t for t in tabs if is_meta(t)]
    stage = [t for t in tabs if is_stage(t)]
    layers = [dict(title=core_title, text=core_text, tables=core)]
    if meta:
        layers.append(dict(title="Metadata and load control", tables=meta,
            text="Registries, routing maps and the parameters the loaders read."))
    if stage:
        layers.append(dict(title="Staging", tables=stage,
            text="Where a delivery lands before it is applied. Staging tables "
                 "hold source names, so they have no relationships."))
    if archive:
        layers.append(dict(title="Raw layer (archive)", db="archive",
                           tables=archive.tables(), text=ARCHIVE_TEXT))
    return layers

def anchor_layers(build, archive):
    tabs = build.tables()
    knots = ["EST_ExistenceStatus", "OST_OrderStatus", "CUR_Currency"]
    core = [t for t in tabs if not is_stage(t) and not is_meta(t)]
    pick = lambda p: [t for t in core if t.startswith(p)]
    rest = default_layers(build, archive)[1:]
    return [
        dict(title="Overview — keys only", tables=core, keys_only=True,
             text="All 24 tables of the constellation with their key columns: "
                  "three anchors, their attributes, three knots and two ties."),
        dict(title="Customer anchor", tables=pick("CU_") + ["EST_ExistenceStatus"],
             text="One table per attribute. Presence is the existence attribute, "
                  "which points at a knot."),
        dict(title="Product anchor",
             tables=pick("PR_") + ["EST_ExistenceStatus", "CUR_Currency"], text=""),
        dict(title="Order anchor and ties",
             tables=pick("OD_") + knots + ["CU_Customer", "PR_Product"],
             context=["CU_Customer", "PR_Product"],
             text="The two ties relate an order to its customer and to its "
                  "products. Customer and product show their keys only."),
    ] + rest

def uss_layers(build, archive):
    rest = default_layers(build, archive)[1:]
    return [
        dict(title="Insert-only core",
             tables=["core_customer", "core_order", "core_order_line", "core_product"],
             text="History lives here. The Unified Star Schema is a presentation "
                  "model, so this demo puts it on a core of its own."),
        dict(title="Unified Star Schema (presentation layer)",
             tables=["customer", "product", "orders", "order_line", "_bridge",
                     "ref_order_status"],
             text="Re-derived from the core after every delivery. Every table "
                  "joins only to the bridge, through its own `_key_` column."),
    ] + rest

def metrics_layers(build, archive):
    rest = default_layers(build, archive)[1:]
    return [
        dict(title="Overview — keys only", keys_only=True,
             tables=["res_type", "res_type_rel", "res", "res_alias", "res_grp",
                     "res_resgrp", "value_type", "metric", "provider",
                     "metric_sample", "metric_summary", "metric_weekly",
                     "grp_metric_weekly", "cal_evt_type", "cal_evt_grp", "calndr_event"],
             text="Every table that has a relationship, with its key columns."),
        dict(title="Resources and groups",
             tables=["res_type", "res_type_rel", "res", "res_alias", "res_grp", "res_resgrp"],
             text="What exists. `RES` holds every resource of every type, "
                  "`RES_ALIAS` maps each provider's name for one to a `res_id`, "
                  "and `RES_RESGRP` puts resources in groups."),
        dict(title="Metrics and aggregations",
             tables=["res", "metric", "value_type", "provider", "metric_sample",
                     "metric_summary", "metric_weekly", "res_grp", "grp_metric_weekly"],
             context=["res", "res_grp"],
             text="What was measured. A metric is a row in `METRIC`, and "
                  "`METRIC_SAMPLE` holds one observation per resource, metric, "
                  "provider and moment. The other three are derived from it."),
        dict(title="Calendar",
             tables=["res_grp", "cal_evt_type", "cal_evt_grp", "calndr_event", "calndr"],
             context=["res_grp"],
             text="What was planned. Every event targets a `RES_GRP`. `CALNDR` "
                  "has no foreign keys: events are matched to it by date."),
        dict(title="Extensions for the shared corpus",
             tables=["res", "res_customer", "res_product", "res_order",
                     "order_status", "currency"], context=["res"],
             text="Subtype and code tables added for attributes `RES` has no "
                  "column for."),
    ] + rest

METRIC_LABELS = {
    ("res", "parent_res"): "parent of", ("res_grp", "parent_res_grp"): "parent of",
    ("res", "res_type"): "classifies", ("res_alias", "res_id"): "is known as",
    ("res_alias", "res_type"): "scopes", ("res_resgrp", "res_id"): "belongs to",
    ("res_resgrp", "res_grp_id"): "has member",
    ("res_type_rel", "parent_res_type"): "may parent",
    ("res_type_rel", "child_res_type"): "may be child",
    ("metric", "value_type"): "types",
    ("metric_sample", "res_id"): "is measured by",
    ("metric_sample", "metric_id"): "is observed as",
    ("metric_sample", "provider_id"): "reports",
    ("metric_summary", "res_id"): "is summarised by",
    ("metric_summary", "metric_id"): "is summarised as",
    ("metric_summary", "provider_id"): "reports",
    ("metric_weekly", "res_id"): "rolls up to",
    ("metric_weekly", "metric_id"): "rolls up as",
    ("metric_weekly", "provider_id"): "reports",
    ("grp_metric_weekly", "res_id"): "rolls up in",
    ("grp_metric_weekly", "res_grp_id"): "rolls up",
    ("grp_metric_weekly", "metric_id"): "rolls up as",
    ("grp_metric_weekly", "provider_id"): "reports",
    ("calndr_event", "res_grp_id"): "is the target of",
    ("calndr_event", "cal_evt_type"): "types",
    ("calndr_event", "event_grp_id"): "collects",
    ("res_customer", "res_id"): "is a", ("res_product", "res_id"): "is a",
    ("res_order", "res_id"): "is a", ("res_order", "status_code"): "decodes",
    ("res_order", "currency_code"): "prices", ("res_product", "currency_code"): "prices",
}

# (parent, child, label): joins the model intends but does not declare.
SOLUTIONS = [
    dict(dir="v3_inmon-3nf", name="Inmon 3NF EDW", notes="INMON.md",
         build="build/edw.db", archive="archive/edw_archive.db",
         core_text="Time-variant entities keyed on the natural key plus "
                   "`valid_from`. The model declares no foreign keys, because a "
                   "reference is to an entity and not to one of its versions.",
         logical=[("customer", "orders", "customer_ref"),
                  ("orders", "order_line", "order_ref"),
                  ("product", "order_line", "sku"),
                  ("order_status_ref", "orders", "status")]),
    dict(dir="v3_data-marts", name="Kimball star", notes="DATAMART.md",
         build="build/datamart.db", archive="archive/datamart_archive.db",
         core_text="Two facts over conformed dimensions. A fact row holds the "
                   "surrogate key of the dimension version current at load."),
    dict(dir="v3_datavault", name="Data Vault 2.0", notes="DATAVAULT.md",
         build="build/datavault.db", archive="archive/datavault_archive.db",
         core_text="Hubs (`_h`), links (`_l`), satellites (`_hsat`), status "
                   "satellites (`_sts`) and one effectivity satellite."),
    dict(dir="v3_focal-point", name="Focal Point", notes="FOCALPOINT.md",
         build="build/focal.db", archive="archive/focal_archive.db",
         core_text="Three generic tables per entity (`_idfr`, `_focal`, `_desc`) "
                   "and one `_x` table per relationship. The core declares no "
                   "foreign keys; `type_key` values are defined in the metadata.",
         logical=[(e + "_focal", e + "_idfr", e + "_key") for e in ("customer", "order", "product")]
               + [(e + "_focal", e + "_desc", e + "_key") for e in ("customer", "order", "product")]
               + [("order_focal", "order_customer_x", "order_key"),
                  ("customer_focal", "order_customer_x", "customer_key"),
                  ("order_focal", "order_product_x", "order_key"),
                  ("product_focal", "order_product_x", "product_key")]),
    dict(dir="v3_anchor", name="Anchor Modeling", notes="ANCHOR.md",
         build="build/anchor.db", archive="archive/anchor_archive.db",
         layers=anchor_layers),
    dict(dir="v3_hook", name="HOOK", notes="HOOK.md",
         build="build/hook.db", archive="archive/hook_archive.db",
         core_text="One frame per source table. Frames relate only by carrying "
                   "the same hook value, so the lines here are joins on `hk_` "
                   "columns, not constraints.",
         logical=[("frame__crm__customer", "frame__oms__order", "hk_customer"),
                  ("frame__oms__order", "frame__oms__order_line", "hk_order"),
                  ("frame__pim__product", "frame__oms__order_line", "hk_product"),
                  ("ref_oms_order_status", "frame__oms__order", "status")]),
    dict(dir="v3_unified-star-schema", name="Unified Star Schema", notes="USS.md",
         build="build/uss.db", archive="archive/uss_archive.db", layers=uss_layers,
         logical=[("core_customer", "core_order", "customer_ref"),
                  ("core_order", "core_order_line", "order_ref"),
                  ("core_product", "core_order_line", "sku"),
                  ("customer", "_bridge", "_key_customer"),
                  ("product", "_bridge", "_key_product"),
                  ("orders", "_bridge", "_key_orders"),
                  ("order_line", "_bridge", "_key_order_line"),
                  ("ref_order_status", "orders", "status_code")]),
    dict(dir="v3_activity-schema", name="Activity Schema", notes="ACTIVITY.md",
         build="build/activity.db", archive="archive/activity_archive.db",
         core_text="Two streams with the same fixed columns. Activities relate "
                   "by who (`customer`), what (`link`) and when (`ts`), so there "
                   "is nothing to draw between them. The order status code lives "
                   "inside `feature_json` and is decoded on read."),
    dict(dir="v3_metrics-mart", name="Metrics mart", notes="METRICSMART.md",
         build="build/metrics.db", archive="archive/metrics_archive.db",
         layers=metrics_layers, labels=METRIC_LABELS, upper=True),
    dict(dir="v3_one-big-table", name="One Big Table", notes="OBT.md",
         build="build/obt.db", archive="archive/obt_archive.db",
         core_text="Full-refresh tables recomputed from the log. `obt_order_wide` "
                   "is the one big table; it repeats the others' columns and "
                   "joins to nothing.",
         logical=[("obt_customer", "obt_orders", "customer_ref"),
                  ("obt_orders", "obt_order_lines", "order_ref"),
                  ("obt_product", "obt_order_lines", "sku")]),
]

# ------------------------------------------------------------------- output
def build(sol):
    """Return (markdown, [(title, mermaid source)]) for one solution."""
    bpath = os.path.join(ROOT, sol["dir"], sol["build"])
    if not os.path.exists(bpath):
        print("  skipped %s: %s not found (run `make demo` there)" % (sol["dir"], sol["build"]))
        return None, []
    dbs = {"build": Db(bpath)}
    apath = sol["archive"] and os.path.join(ROOT, sol["dir"], sol["archive"])
    dbs["archive"] = Db(apath) if apath and os.path.exists(apath) else None
    make = sol.get("layers")
    layers = (make(dbs["build"], dbs["archive"]) if make else
              default_layers(dbs["build"], dbs["archive"], core_text=sol.get("core_text", "")))
    n_logical = len(sol.get("logical", []))
    md = ["# %s — ER diagrams" % sol["name"], "",
          "Generated from [`%s/%s`](../../%s/%s)%s by `er-diagrams/generate.py`. "
          "Design notes: [`%s/%s`](../../%s/%s)." % (
              sol["dir"], sol["build"], sol["dir"], sol["build"],
              " and `%s`" % sol["archive"] if dbs["archive"] else "",
              sol["dir"], sol["notes"], sol["dir"], sol["notes"]), "",
          "> `PK` is a primary-key column and `FK` a declared foreign key. A solid",
          "> line is a declared foreign key; a dashed line is a join the model",
          "> intends but does not declare. The crow's foot is the \"many\" side.", ""]
    if n_logical:
        md += ["This model declares %s of its relationships as foreign keys, so "
               "%d dashed lines were added by hand in the generator." % (
                   "none" if not any(dbs["build"].fks(t) for t in dbs["build"].tables()
                                     if not is_meta(t)) else "only some", n_logical), ""]
    pages = []
    for i, layer in enumerate(layers, 1):
        db = dbs[layer.get("db", "build")]
        src = diagram(db, layer, sol)
        title = "%d · %s" % (i, layer["title"])
        md += ["## " + title, ""]
        if layer.get("text"):
            md += [layer["text"], ""]
        md += ["```mermaid", src, "```", ""]
        pages.append(("%s — %s" % (sol["name"], layer["title"]), src))
    return "\n".join(md), pages

def render_pdf(pages, out):
    from pypdf import PdfWriter
    cfg = os.path.join(HERE, "puppeteer.json")
    writer = PdfWriter()
    with tempfile.TemporaryDirectory() as tmp:
        for n, (title, src) in enumerate(pages):
            mmd = os.path.join(tmp, "p%02d.mmd" % n)
            pdf = os.path.join(tmp, "p%02d.pdf" % n)
            with open(mmd, "w") as f:
                f.write('---\ntitle: "%s"\n---\n%s\n' % (title, src))
            cmd = ["mmdc", "-i", mmd, "-o", pdf, "--pdfFit", "-b", "white", "-w", "4000"]
            if os.path.exists(cfg):
                cmd += ["-p", cfg]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
            writer.append(pdf)
        with open(out, "wb") as f:
            writer.write(f)

def main():
    want_pdf = "--pdf" in sys.argv
    if want_pdf and not shutil.which("mmdc"):
        sys.exit("--pdf needs the Mermaid CLI: npm install -g @mermaid-js/mermaid-cli")
    for d in ("mermaid", "pdf"):
        os.makedirs(os.path.join(HERE, d), exist_ok=True)
    for sol in SOLUTIONS:
        md, pages = build(sol)
        if md is None:
            continue
        stem = sol["dir"].replace("v3_", "")
        with open(os.path.join(HERE, "mermaid", stem + ".md"), "w") as f:
            f.write(md)
        msg = "  %-22s %d diagram(s)" % (stem, len(pages))
        if want_pdf:
            render_pdf(pages, os.path.join(HERE, "pdf", stem + ".pdf"))
            msg += " + pdf"
        print(msg)

if __name__ == "__main__":
    main()
