import Foundation

/// The films whose makers publish characteristic curves, past the first three Kodak sheets: each
/// channel's slope over the straight part of the sheet's Status M curves, fitted from one log H
/// either side of the normal exposure of a midscale neutral (the sheet's own Log H Ref; else
/// log₁₀(14.4 / ISO), which every Kodak ref here follows to 0.01, or the sheet's camera stop 0).
/// Traced on 2026-11-10 from the sheets' vector drawings, or off the pictures some sheets print
/// instead, the picture tracer checked against a vector trace of the same plot to within 0.006.
/// Named as the catalog's films (`FilmStock.name`), so a roll of the film finds its preset; the
/// catalog links each stock to its id. The scripts and checks: outputs/数据表曲线-2026-11-10.
enum FilmDataSheets {
  static let traced = "按厂家数据表的特性曲线描摹：Status M 密度，取正常曝光点前后各 1（log H）的直线段斜率；不是扫描仪 ICC 标定。片基与色阶由当前扫描估计。"
  private static let cine = "电影负片的数据表，按 ECN-2 冲洗测得；按 C-41 冲洗时反差更高，斜率只能作起点。"
  private static let picture = "曲线从数据表印的图上描摹。"

  private static func sheet(
    _ id: String, _ name: String, iso: Int, process: String, url: String, publication: String,
    _ r: Double, _ g: Double, _ b: Double, note: String = ""
  ) -> FilmProfile {
    FilmProfile(
      id: id, name: name, aliases: [id, name.lowercased()], iso: iso, process: process, sourceURL: url,
      publication: publication, slopes: RGB(r: r, g: g, b: b), notes: traced + (note.isEmpty ? "" : " " + note))
  }

  static let presets: [FilmProfile] = [
    sheet("portra800", "Kodak Portra 800", iso: 800, process: "C-41 · 日光",
      url: "https://kodakprofessional.com/sites/default/files/2025-07/e4040.pdf", publication: "Kodak E-4040 · p.4",
      0.684, 0.721, 0.780),
    sheet("gold200", "Kodak Gold 200", iso: 200, process: "C-41 · 日光",
      url: "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/E7022%20Gold%20tech%20sheet.pdf",
      publication: "Kodak E-7022 · p.4", 0.541, 0.564, 0.616),
    sheet("ultramax400", "Kodak UltraMax 400", iso: 400, process: "C-41 · 日光",
      url: "https://kodakprofessional.com/sites/default/files/wysiwyg/KodakUltraMax400TechSheet-1.pdf",
      publication: "Kodak E-7023 · p.4", 0.500, 0.529, 0.581),
    sheet("vision3-50d", "Kodak Vision3 50D 5203", iso: 50, process: "ECN-2 · 日光",
      url: "https://www.kodak.com/content/pdfs/motion/KODAK-VISION3-50D-5203-7203-technical-information.pdf",
      publication: "Kodak H-1-5203 · p.3", 0.470, 0.557, 0.535, note: cine + picture),
    sheet("vision3-250d", "Kodak Vision3 250D 5207", iso: 250, process: "ECN-2 · 日光",
      url: "https://www.kodak.com/content/pdfs/motion/KODAK-VISION3-250D-5207-7207-technical-information.pdf",
      publication: "Kodak H-1-5207 · p.3", 0.475, 0.557, 0.540, note: cine + picture),
    sheet("vision3-200t", "Kodak Vision3 200T 5213", iso: 200, process: "ECN-2 · 灯光 3200K",
      url: "https://www.kodak.com/content/pdfs/motion/KODAK-VISION3-200T-5213-7213-technical-information.pdf",
      publication: "Kodak H-1-5213 · p.3", 0.479, 0.559, 0.535, note: cine + "3200K 灯光下曝光测得。" + picture),
    sheet("vision3-500t", "Kodak Vision3 500T 5219", iso: 500, process: "ECN-2 · 灯光 3200K",
      url: "https://www.kodak.com/content/pdfs/motion/KODAK-VISION3-500T-5219-7219-technical-information.pdf",
      publication: "Kodak H-1-5219 · p.3", 0.456, 0.535, 0.519, note: cine + "3200K 灯光下曝光测得。" + picture),
    sheet("fujifilm200", "Fujifilm 200", iso: 200, process: "C-41（CN-16）· 日光",
      url: "https://asset.fujifilm.com/www/us/files/2022-02/f4606a5c43dacb389a1d9eb35e0b18db/fujifilm-200-speed-film_data-sheet.pdf",
      publication: "Fujifilm AF3-0261E · p.5", 0.539, 0.633, 0.616),
    sheet("fujifilm400", "Fujifilm 400", iso: 400, process: "C-41（CN-16）· 日光",
      url: "https://www.ishootfujifilm.com/uploads/SUPERIA%20400%20Data%20Sheet.pdf",
      publication: "Fujifilm AF3-0262E · p.6", 0.565, 0.633, 0.597),
    sheet("fujicolor100", "Fujifilm Fujicolor 100", iso: 100, process: "C-41（CN-16）· 日光",
      url: "https://asset.fujifilm.com/www/jp/files/2019-12/05b4b671ff6c0e53b8f7df233d57dfd7/datasheet_fujicolor100_01.pdf",
      publication: "Fujifilm 013AR0317A · p.5", 0.784, 0.750, 0.805),
    sheet("superia-premium400", "Fujifilm Superia Premium 400", iso: 400, process: "C-41（CN-16）· 日光",
      url: "https://asset.fujifilm.com/www/jp/files/2019-12/3723e0912cf7e939bb07fd982b0ff9fa/datasheet_superiapremium400_01.pdf",
      publication: "Fujifilm 013AR0324A · p.5", 0.670, 0.681, 0.732),
    sheet("superia-xtra400", "Fujifilm Superia X-TRA 400", iso: 400, process: "C-41（CN-16）· 日光",
      url: "https://asset.fujifilm.com/master/emea/files/2020-10/9a958fdcc6bd1442a06f71e134b811f6/films_superia-xtra400_datasheet_01.pdf",
      publication: "Fujifilm AF3-0217E · p.6", 0.609, 0.665, 0.708),
    sheet("fujicolor-c200", "Fujifilm Fujicolor C200", iso: 200, process: "C-41（CN-16）· 日光",
      url: "https://asset.fujifilm.com/master/emea/files/2020-10/98c3d5087c253f51c132a5d46059f131/films_c200_datasheet_01.pdf",
      publication: "Fujifilm AF3-0249E · p.6", 0.599, 0.638, 0.665, note: picture),
    sheet("pro400h", "Fujifilm Pro 400H", iso: 400, process: "C-41 · 日光",
      url: "https://asset.fujifilm.com/master/emea/files/2020-10/a6cb96275e4957ddc7b3ca932b7755e5/films_pro-400h_datasheet_01.pdf",
      publication: "Fujifilm AF3-176E · p.8", 0.582, 0.557, 0.530, note: picture),
    sheet("pro160ns", "Fujifilm Pro 160NS", iso: 160, process: "C-41（CN-16）· 日光",
      url: "https://asset.fujifilm.com/www/jp/files/2024-04/6b75b1c1cb4253623fb2cd7a56ff7443/datasheet_pro160ns_01.pdf",
      publication: "Fujifilm 163AR109A · p.8", 0.595, 0.540, 0.549),
    sheet("wolfen-nc500", "ORWO Wolfen NC500", iso: 400, process: "C-41 · 日光",
      url: "https://filmotec.de/wp-content/uploads/2023/04/Datenblatt-Wolfen-NC500.pdf",
      publication: "ORWO Datenblatt WOLFEN NC500 · S.2", 0.393, 0.387, 0.312,
      note: "这款的曲线全程弯曲、直线段短，斜率是近似；数据表注明按 ECN-2 冲洗反差更低。"),
    sheet("wolfen-nc400", "ORWO Wolfen NC400", iso: 400, process: "C-41 · 日光",
      url: "https://filmotec.de/wp-content/uploads/2024/09/Datenblatt-NC400_20240916.pdf",
      publication: "ORWO Datenblatt NC400 · S.2", 0.627, 0.632, 0.640),
    sheet("phoenix200", "Harman Phoenix 200", iso: 200, process: "C-41 · 日光",
      url: "https://www.harmanphoto.co.uk/amfile/file/download/file/1963/product/2143/",
      publication: "HARMAN PHOENIX 200（2024-09）· p.3", 1.366, 1.363, 1.527,
      note: "数据表的横轴是相对曝光量，没有正常曝光点：取绿通道密度在 25%–75% 之间的一段。这款的反差比一般彩色负片高得多。" + picture),
  ]
}
