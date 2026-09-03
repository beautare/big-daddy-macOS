import XCTest
import CoreGraphics
@testable import BigDaddy

/// 相似度去重的行为契约。
///
/// 这套逻辑失败时是**完全静默**的：判成"相似"就是少发一轮，没有异常、没有日志、
/// 没有任何人会发现。而 AI 模式下它的一次误判恰恰会把整个功能最想抓的场景
/// （角落里偷偷放视频）滤掉——漏斗把目标本身滤走了，还看不出来。
final class ScreenshotBlockwiseDedupTests: XCTestCase {

    /// 造一张纯色底图，可选地在右下角画一个小方块，模拟画中画视频窗。
    /// - Parameter cornerRatio: 小方块边长占整图边长的比例。0 = 不画。
    private func image(background: CGFloat, cornerRatio: CGFloat, cornerGray: CGFloat) -> CGImage {
        let side = 512
        let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // setGray 是 AppKit 的 NSGraphicsContext API，CGContext 上没有；
        // 灰度色彩空间里直接用 setFillColor(gray:alpha:)。
        context.setFillColor(gray: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if cornerRatio > 0 {
            let boxSide = CGFloat(side) * cornerRatio
            context.setFillColor(gray: cornerGray, alpha: 1)
            context.fill(CGRect(x: CGFloat(side) - boxSide, y: 0, width: boxSide, height: boxSide))
        }
        return context.makeImage()!
    }

    private func makeClient() -> BigDaddyClient {
        BigDaddyClient()
    }

    /// 这是本次改动**唯一的存在理由**，也是最该被钉死的一条。
    ///
    /// 真实的"角落里偷偷放视频"长什么样：那个画中画窗口在**两帧里都存在**，变的只是
    /// 它内部的画面内容——屏幕其余部分（作业文档、代码编辑器）纹丝不动。
    ///
    /// 于是在 8×8 灰度缩略图上，只有 4 个像素发生了中等幅度的变化，平均 diff 被其余
    /// 60 个静止像素稀释到远低于阈值 8 —— AI 模式最想抓的场景，被第一关无声滤掉。
    /// 分块版取各块的**最大**差值，不会被稀释。
    ///
    /// 注：如果那个小窗是"从无到有"地突然出现、而且是纯黑贴在中灰底上（对比度拉满），
    /// 全局平均**也能**测出来。所以这里刻意用"窗口一直在、内容在变"这个真实形态，
    /// 而不是挑一个对分块版最有利的极端例子——用后者写出来的绿测试没有意义。
    func testPlayingVideoInCornerWindowIsMissedByGlobalAverageButCaughtByBlockwise() {
        let displayID: CGDirectDisplayID = 1
        // 1/4 边长 = 1/16 面积的画中画。两帧里窗口都在，只有内容明暗变了（视频在播）。
        let frameA = image(background: 0.5, cornerRatio: 0.25, cornerGray: 0.35)
        let frameB = image(background: 0.5, cornerRatio: 0.25, cornerGray: 0.65)

        let globalClient = makeClient()
        _ = globalClient.isImageSimilarToLast(cgImage: frameA, displayID: displayID)
        let globalSaysSimilar = globalClient.isImageSimilarToLast(cgImage: frameB, displayID: displayID)

        let blockClient = makeClient()
        _ = blockClient.isImageSimilarToLastBlockwise(cgImage: frameA, displayID: displayID)
        let blockSaysSimilar = blockClient.isImageSimilarToLastBlockwise(cgImage: frameB, displayID: displayID)

        XCTAssertTrue(globalSaysSimilar,
                      "全局平均把小窗的变化稀释掉了——这一条在记录问题本身，不是在要求它被修好")
        XCTAssertFalse(blockSaysSimilar,
                       "分块版必须看见角落里正在播放的小窗，否则 AI 模式抓不到隐蔽分心")
    }

    func testFirstFrameIsNeverSimilar() {
        // 没有上一帧可比时必须判为"有变化"：判成相似会让设备开机后的第一轮静默丢弃，
        // 而那一轮恰恰是家长最想看到的。
        let client = makeClient()
        XCTAssertFalse(client.isImageSimilarToLastBlockwise(
            cgImage: image(background: 0.5, cornerRatio: 0, cornerGray: 0), displayID: 1))
    }

    func testIdenticalFramesAreSimilar() {
        let client = makeClient()
        let frame = image(background: 0.5, cornerRatio: 0, cornerGray: 0)
        _ = client.isImageSimilarToLastBlockwise(cgImage: frame, displayID: 1)
        XCTAssertTrue(client.isImageSimilarToLastBlockwise(cgImage: frame, displayID: 1),
                      "完全相同的画面必须判为相似，否则去重形同虚设、每一轮都上传")
    }

    /// 多屏下每块屏必须和**自己的**上一帧比。共用一个槽位时，主屏静止 + 副屏播视频
    /// 会让两屏轮流覆盖同一份指纹，比较的永远是"这块屏 vs 另一块屏"，去重彻底失效。
    func testEachDisplayIsComparedAgainstItsOwnPreviousFrame() {
        let client = makeClient()
        let dark = image(background: 0.1, cornerRatio: 0, cornerGray: 0)
        let light = image(background: 0.9, cornerRatio: 0, cornerGray: 0)

        _ = client.isImageSimilarToLastBlockwise(cgImage: dark, displayID: 1)
        _ = client.isImageSimilarToLastBlockwise(cgImage: light, displayID: 2)

        XCTAssertTrue(client.isImageSimilarToLastBlockwise(cgImage: dark, displayID: 1),
                      "屏 1 应当和屏 1 的上一帧比，而不是和屏 2 比")
        XCTAssertTrue(client.isImageSimilarToLastBlockwise(cgImage: light, displayID: 2))
    }

    /// 两个版本各自分桶保存指纹：采样尺寸不同（8×8 = 64 字节 vs 16×16 = 256 字节），
    /// 共用槽位会在家长切换推送模式的那一轮拿 64 个字节去比 256 个字节。
    func testGlobalAndBlockwiseKeepSeparateFingerprints() {
        let client = makeClient()
        let frame = image(background: 0.5, cornerRatio: 0, cornerGray: 0)

        _ = client.isImageSimilarToLast(cgImage: frame, displayID: 1)
        // 分块版此时还没有属于自己的上一帧，必须判为"有变化"而不是去读全局版的槽位
        XCTAssertFalse(client.isImageSimilarToLastBlockwise(cgImage: frame, displayID: 1),
                       "两个版本的指纹不能共用一个槽位")
    }
}
