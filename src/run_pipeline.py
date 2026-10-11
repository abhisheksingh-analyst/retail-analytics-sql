"""
run_pipeline.py - end-to-end retail analytics pipeline.

    python src/run_pipeline.py

Steps
  1. Load the 3 raw CSVs into a SQLite database (outputs/retail.db).
  2. Execute the SQL files in /sql in order. Every query tagged
     "-- name: xyz" is exported to outputs/tables/xyz.csv.
  3. Run statistical tests that check whether the patterns found by SQL
     are real or could be random noise  -> outputs/tables/statistical_tests.csv
  4. Draw the figures                      -> outputs/figures/*.png

Python is used only for what SQL cannot do well (hypothesis tests,
bootstrap, k-means, charts). All business logic (cleaning, KPIs,
segmentation) lives in SQL.
"""
import re
import sqlite3
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats
from sklearn.cluster import KMeans
from sklearn.metrics import adjusted_rand_score, silhouette_score
from sklearn.preprocessing import StandardScaler

ROOT = Path(__file__).resolve().parents[1]
RAW, SQL_DIR = ROOT / "data" / "raw", ROOT / "sql"
TAB, FIG = ROOT / "outputs" / "tables", ROOT / "outputs" / "figures"
DB = ROOT / "outputs" / "retail.db"
SEED = 42
ALPHA = 0.05

TAB.mkdir(parents=True, exist_ok=True)
FIG.mkdir(parents=True, exist_ok=True)

# colour-blind-friendly palette
C = {"blue": "#2b6cb0", "orange": "#dd6b20", "green": "#2f855a", "red": "#c53030",
     "grey": "#718096", "purple": "#6b46c1", "light": "#cbd5e0"}
plt.rcParams.update({"figure.dpi": 130, "axes.spines.top": False, "axes.spines.right": False,
                     "axes.grid": True, "grid.alpha": 0.25, "font.size": 10,
                     "axes.titlesize": 12, "axes.titleweight": "bold"})


# ----------------------------------------------------------------------
# 1. Load raw data
# ----------------------------------------------------------------------
def load_raw(con):
    files = {"raw_sales": "sales_transaction.csv",
             "raw_customers": "customer_profiles.csv",
             "raw_products": "product_inventory.csv"}
    for table, fname in files.items():
        df = pd.read_csv(RAW / fname)          # dates stay as text; SQL parses them
        df.to_sql(table, con, if_exists="replace", index=False)
        print(f"  loaded {table:14s} {len(df):>5} rows")


# ----------------------------------------------------------------------
# 2. Run SQL files
# ----------------------------------------------------------------------
MARKER = re.compile(r"^-- (name: \S+|setup)[ \t]*$", re.M)


def run_sql_file(con, path):
    """Blocks marked '-- setup' are executed (CREATE/DROP);
    blocks marked '-- name: x' are run as queries and saved as x.csv."""
    text = path.read_text()
    parts = MARKER.split(text)                 # [preamble, marker1, body1, marker2, body2, ...]
    out = {}
    for marker, body in zip(parts[1::2], parts[2::2]):
        if marker == "setup":
            con.executescript(body)
        else:
            name = marker.split(":", 1)[1].strip()
            df = pd.read_sql_query(body.strip().rstrip(";"), con)
            df.to_csv(TAB / f"{name}.csv", index=False)
            out[name] = df
    return out


# ----------------------------------------------------------------------
# 3. Statistical checks
# ----------------------------------------------------------------------
def holm(pvals):
    """Holm-Bonferroni adjusted p-values (controls family-wise error)."""
    p = np.asarray(pvals, float)
    order = np.argsort(p)
    adj = np.empty_like(p)
    running = 0.0
    for rank, i in enumerate(order):
        running = max(running, (len(p) - rank) * p[i])
        adj[i] = min(1.0, running)
    return adj


def cramers_v(ct):
    chi2, p, dof, _ = stats.chi2_contingency(ct)
    n = ct.values.sum()
    return chi2, p, dof, float(np.sqrt(chi2 / (n * (min(ct.shape) - 1))))


def kruskal_eta2(groups):
    h, p = stats.kruskal(*groups)
    n, k = sum(len(g) for g in groups), len(groups)
    return h, p, max(0.0, (h - k + 1) / (n - k))


def run_stats(con, tables):
    rows = []

    def add(test, question, stat, p, effect, effect_name, note=""):
        rows.append(dict(test=test, question=question, statistic=round(float(stat), 4),
                         p_value=float(p), effect_size=round(float(effect), 4),
                         effect_name=effect_name, note=note))

    pp = pd.read_sql_query("SELECT * FROM product_perf", con)
    half = tables["product_half_split"]
    cust = pd.read_sql_query("SELECT * FROM customer_rfm", con)
    daily = tables["eda_daily_revenue"].query("complete_day == 1").copy()   # last day is partial

    # --- T1: are some products really bought more often than others? ---
    chi2, p = stats.chisquare(pp["Transactions"])
    add("Chi-square goodness-of-fit", "Do products differ in how OFTEN they are bought (vs. all equally likely)?",
        chi2, p, pp["Transactions"].std() / pp["Transactions"].mean(), "coef. of variation",
        "p large -> purchase counts are consistent with every product being equally popular")

    # --- T2: do product rankings persist over time? ---
    for col, lab in [("units", "units sold"), ("revenue", "revenue")]:
        rho, p = stats.spearmanr(half[f"{col}_h1"], half[f"{col}_h2"])
        add("Spearman (split-half)", f"Is a product's rank by {lab} in Jan-Apr predictive of May-Jul?",
            rho, p, rho, "rho", "rho near 0 -> 'top sellers' are not persistent")

    # --- T3: what drives product revenue: price or demand? ---
    rho_rp, p_rp = stats.spearmanr(pp["Price"], pp["Revenue"])
    add("Spearman", "Is product revenue related to product price?", rho_rp, p_rp, rho_rp, "rho",
        "high rho -> revenue ranking mostly reflects price, not popularity")
    rho_up, p_up = stats.spearmanr(pp["Price"], pp["Units"])
    add("Spearman", "Is units sold related to product price?", rho_up, p_up, rho_up, "rho")

    # --- T4: categories ---
    g = [d["Revenue"].values for _, d in pp.groupby("Category")]
    h, p, e = kruskal_eta2(g)
    add("Kruskal-Wallis", "Does revenue per product differ across categories?", h, p, e, "eta-squared")
    g = [d["Units"].values for _, d in pp.groupby("Category")]
    h, p, e = kruskal_eta2(g)
    add("Kruskal-Wallis", "Does units sold per product differ across categories?", h, p, e, "eta-squared")

    # --- T5: is there a sales trend? ---
    daily["t"] = np.arange(len(daily))
    lr = stats.linregress(daily["t"], daily["revenue"])
    pct30 = 100 * lr.slope * 30 / daily["revenue"].mean()
    add("Linear regression", "Is daily revenue trending up or down over Jan-Jul 2023 (complete days)?",
        lr.slope, lr.pvalue, pct30, "% change per 30 days", f"slope={lr.slope:.2f}/day, r={lr.rvalue:.3f}")

    # --- T6: demographics vs spend ---
    c = cust.copy()
    for dim in ["Gender", "Location", "AgeGroup"]:
        d = c[(c[dim].notna()) & (c[dim] != "Unknown")]
        h, p, e = kruskal_eta2([x["Monetary"].values for _, x in d.groupby(dim)])
        add("Kruskal-Wallis", f"Does customer spend differ by {dim}?", h, p, e, "eta-squared")
    d = c.dropna(subset=["Age"])
    rho, p = stats.spearmanr(d["Age"], d["Monetary"])
    add("Spearman", "Is customer age related to spend?", rho, p, rho, "rho")
    snapshot = pd.to_datetime(tables["eda_overview"]["last_date"].iloc[0]) + pd.Timedelta(days=1)
    c["tenure_days"] = (snapshot - pd.to_datetime(c["JoinDate"])).dt.days
    rho, p = stats.spearmanr(c["tenure_days"], c["Monetary"])
    add("Spearman", "Do longer-standing customers (earlier join date) spend more?", rho, p, rho, "rho")

    # --- T7: are segments just demographics in disguise? ---
    for dim in ["Gender", "Location", "AgeGroup"]:
        d = c[(c[dim].notna()) & (c[dim] != "Unknown")]
        ct = pd.crosstab(d["Segment"], d[dim])
        chi2, p, dof, v = cramers_v(ct)
        add("Chi-square independence", f"Are RFM segments associated with {dim}?", chi2, p, v, "Cramer's V")

    # --- T8: do purchases look randomly assigned to customers? ---
    n_all = int(tables["eda_overview"]["total_customers"].iloc[0])
    counts = np.concatenate([cust["Frequency"].values, np.zeros(n_all - len(cust))])
    disp = counts.var(ddof=1) / counts.mean()
    p_disp = 2 * min(stats.chi2.cdf((n_all - 1) * disp, n_all - 1), stats.chi2.sf((n_all - 1) * disp, n_all - 1))
    add("Index of dispersion", "Is the spread of purchases per customer larger than pure chance (Poisson)?",
        (n_all - 1) * disp, p_disp, disp, "variance/mean",
        "index ~1 -> customers' purchase counts look like random draws; real loyalty usually gives >>1")

    res = pd.DataFrame(rows)
    res["p_holm"] = holm(res["p_value"])
    res["significant_after_holm"] = res["p_holm"] < ALPHA
    res.to_csv(TAB / "statistical_tests.csv", index=False)

    # --- Bootstrap: how stable is the 'top/bottom quartile' label of each product? ---
    sales = pd.read_sql_query("SELECT ProductID, Revenue FROM clean_sales", con)
    codes, uniq = pd.factorize(sales["ProductID"], sort=True)
    rev, n, k = sales["Revenue"].values, len(sales), len(uniq)
    q = k // 4
    rng = np.random.default_rng(SEED)
    top_hits, bot_hits, B = np.zeros(k), np.zeros(k), 2000
    for _ in range(B):
        idx = rng.integers(0, n, n)
        r = np.bincount(codes[idx], weights=rev[idx], minlength=k)
        top_hits += r >= np.partition(r, -q)[-q]
        bot_hits += r <= np.partition(r, q - 1)[q - 1]
    boot = pd.DataFrame({"ProductID": uniq, "p_in_top_quartile": top_hits / B,
                         "p_in_bottom_quartile": bot_hits / B}).merge(
        pp[["ProductID", "Price", "Units", "Revenue", "PerformanceTier"]], on="ProductID")
    boot.to_csv(TAB / "bootstrap_quartile_stability.csv", index=False)

    # --- K-means: do natural clusters exist, or is RFM just a convenient partition? ---
    X = StandardScaler().fit_transform(cust[["Recency", "Frequency", "Monetary"]])
    sil = []
    for kk in range(2, 9):
        lab = KMeans(n_clusters=kk, n_init=10, random_state=SEED).fit_predict(X)
        sil.append(dict(k=kk, silhouette=round(silhouette_score(X, lab), 4)))
    sil = pd.DataFrame(sil)
    lab5 = KMeans(n_clusters=5, n_init=10, random_state=SEED).fit_predict(X)
    sil["ari_vs_rfm_rules_at_k5"] = np.where(sil["k"] == 5, round(adjusted_rand_score(cust["Segment"], lab5), 4), np.nan)
    sil.to_csv(TAB / "kmeans_silhouette.csv", index=False)

    return res, boot, sil


# ----------------------------------------------------------------------
# 4. Figures
# ----------------------------------------------------------------------
def save(fig, name):
    fig.tight_layout()
    fig.savefig(FIG / name, bbox_inches="tight")
    plt.close(fig)


def make_figures(con, t, boot, sil):
    pp = pd.read_sql_query("SELECT * FROM product_perf", con)

    # Fig 1 - impact of the price error
    d = t["eda_impact_of_price_correction"].copy()
    d["label"] = "P" + d["ProductID"].astype(str)
    x = np.arange(len(d))
    fig, ax = plt.subplots(figsize=(9, 4))
    ax.bar(x - 0.2, d["revenue_uncleaned"], 0.4, label="Before cleaning", color=C["red"])
    ax.bar(x + 0.2, d["revenue_cleaned"], 0.4, label="After cleaning", color=C["blue"])
    ax.set_xticks(x, d["label"])
    ax.set_ylabel("Revenue")
    ax.set_title("One 100x price error made Product 51 look like the #1 product by far")
    ax.legend()
    save(fig, "fig01_price_error_impact.png")

    # Fig 2 - Pareto
    s = pp.sort_values("Revenue", ascending=False).reset_index(drop=True)
    fig, ax = plt.subplots(figsize=(9, 4))
    ax.bar(range(len(s)), s["Revenue"], color=C["blue"], width=1.0)
    ax.set_ylabel("Revenue per product")
    ax.set_xlabel("Products ranked by revenue")
    ax2 = ax.twinx()
    ax2.plot(range(len(s)), s["CumShare"] * 100, color=C["orange"], lw=2)
    ax2.axhline(80, color=C["grey"], ls="--", lw=1)
    ax2.set_ylabel("Cumulative % of revenue")
    ax2.grid(False)
    n80 = int((s["CumShareBefore"].fillna(0) < 0.8).sum())
    ax.set_title(f"Revenue is only mildly concentrated: {n80} of {len(s)} products ({100*n80/len(s):.0f}%) make 80% of revenue")
    save(fig, "fig02_product_pareto.png")

    # Fig 3 - category
    cat = t["category_performance"]
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.8))
    axes[0].bar(cat["Category"], cat["revenue"], color=C["blue"])
    axes[0].set_title("Revenue")
    axes[1].bar(cat["Category"], cat["units"], color=C["green"])
    axes[1].set_title("Units sold")
    axes[2].bar(cat["Category"], cat["avg_price"], color=C["orange"])
    axes[2].set_title("Average catalog price")
    for a in axes:
        a.tick_params(axis="x", rotation=25)
    fig.suptitle("Categories: revenue differences track price and product count, not unit demand", fontweight="bold", y=1.03)
    save(fig, "fig03_category_performance.png")

    # Fig 4 - inventory matrix
    colors = {"Restock now (<90 days of cover)": C["red"],
              "Overstock (weak seller, high stock)": C["orange"],
              "Out of stock": "black", "Balanced": C["light"]}
    fig, ax = plt.subplots(figsize=(8.5, 5))
    for flag, g in pp.groupby("InventoryFlag"):
        ax.scatter(g["Units"], g["StockLevel"], s=28, color=colors[flag], label=f"{flag} ({len(g)})",
                   edgecolor="white", linewidth=0.4)
    days_obs = int(t["eda_overview"]["days_observed"].iloc[0])
    xs = np.array([pp["Units"].min(), pp["Units"].max()])
    ax.plot(xs, xs / days_obs * 90, color=C["red"], ls="--", lw=1, label="90 days of cover")
    ax.set_xlabel("Units sold (Jan-Jul 2023)")
    ax.set_ylabel("Current stock level")
    ax.set_title("Most products hold far more stock than recent demand needs")
    ax.legend(fontsize=8, loc="upper center", bbox_to_anchor=(0.5, -0.14), ncol=2, frameon=False)
    save(fig, "fig04_inventory_matrix.png")

    # Fig 5 - daily revenue trend
    dr = t["eda_daily_revenue"].query("complete_day == 1").copy()
    dr["date"] = pd.to_datetime(dr["date"])
    tt = np.arange(len(dr))
    lr = stats.linregress(tt, dr["revenue"])
    fig, ax = plt.subplots(figsize=(9, 3.8))
    ax.plot(dr["date"], dr["revenue"], color=C["light"], lw=1, label="Daily revenue")
    ax.plot(dr["date"], dr["revenue"].rolling(7, center=True).mean(), color=C["blue"], lw=2, label="7-day average")
    ax.plot(dr["date"], lr.intercept + lr.slope * tt, color=C["orange"], ls="--", label=f"Linear trend (p={lr.pvalue:.2f})")
    ax.set_ylabel("Revenue")
    ax.set_title("Daily revenue is flat: no statistically detectable growth or decline")
    ax.legend(fontsize=8)
    save(fig, "fig05_daily_revenue_trend.png")

    # Fig 6 - RFM segments
    seg = t["segment_summary"].copy()
    seg["label"] = seg["Segment"].str[2:]
    y = np.arange(len(seg))
    fig, ax = plt.subplots(figsize=(8.5, 4))
    ax.barh(y + 0.2, seg["pct_customers"], 0.4, color=C["grey"], label="% of customers")
    ax.barh(y - 0.2, seg["pct_revenue"], 0.4, color=C["blue"], label="% of revenue")
    ax.set_yticks(y, seg["label"])
    ax.invert_yaxis()
    ax.set_xlabel("%")
    ax.set_title("RFM segments: share of customers vs. share of revenue")
    ax.legend()
    save(fig, "fig06_rfm_segments.png")

    # Fig 7 - behaviour
    freq = t["purchase_frequency_distribution"]
    gaps = t["inter_purchase_gap_raw"]["gap_days"].dropna()
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.8))
    axes[0].bar(freq["purchases"], freq["customers"], color=C["blue"])
    axes[0].set_xlabel("Purchases per customer (7 months)")
    axes[0].set_ylabel("Customers")
    axes[0].set_title("Purchase frequency")
    axes[1].hist(gaps, bins=np.arange(0, 125, 5), color=C["green"], edgecolor="white")
    axes[1].axvline(gaps.median(), color=C["orange"], ls="--", label=f"median = {gaps.median():.0f} days")
    axes[1].set_xlabel("Days between consecutive purchases")
    axes[1].set_title("Time between repeat purchases")
    axes[1].legend()
    save(fig, "fig07_customer_behavior.png")

    # Fig 8 - rank stability
    half = t["product_half_split"]
    rho, p = stats.spearmanr(half["units_h1"], half["units_h2"])
    fig, axes = plt.subplots(1, 2, figsize=(10, 4))
    axes[0].scatter(half["units_h1"], half["units_h2"], s=18, color=C["blue"], alpha=0.7)
    axes[0].set_xlabel("Units sold, Jan-Apr")
    axes[0].set_ylabel("Units sold, May-Jul")
    axes[0].set_title(f"Do 'best sellers' stay best sellers? rho = {rho:.2f}")
    top = boot[boot["PerformanceTier"] == "High"]
    axes[1].hist(top["p_in_top_quartile"], bins=np.linspace(0, 1, 11), color=C["orange"], edgecolor="white")
    axes[1].set_xlabel("Bootstrap probability of staying in top quartile")
    axes[1].set_ylabel("Products labelled 'High'")
    axes[1].set_title("How robust is the 'High performer' label?")
    save(fig, "fig08_ranking_stability.png")


# ----------------------------------------------------------------------
def main():
    if DB.exists():
        DB.unlink()
    con = sqlite3.connect(DB)
    print("1) Loading raw data")
    load_raw(con)
    tables = {}
    print("2) Running SQL")
    for f in sorted(SQL_DIR.glob("0*.sql")):
        res = run_sql_file(con, f)
        tables.update(res)
        print(f"  {f.name}: {len(res)} result tables")
    con.commit()
    print("3) Statistical checks")
    res, boot, sil = run_stats(con, tables)
    print("4) Figures")
    make_figures(con, tables, boot, sil)
    con.close()
    print("\nDone. Tables -> outputs/tables, figures -> outputs/figures")


if __name__ == "__main__":
    main()
