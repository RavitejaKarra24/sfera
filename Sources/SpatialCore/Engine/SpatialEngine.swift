import Foundation

public enum SpatialEngine {
    /// Renders beds and objects to binaural stereo.
    public static func render(
        sources: [RenderSource],
        frames: Int,
        settings: RenderSettings,
        progress: ((Double) -> Void)? = nil
    ) -> (PlanarAudio, RenderStats) {
        let clock = Date()
        var result = BinauralRenderer.render(sources: sources, frames: frames, settings: settings, progress: progress)
        result.1.prepSeconds = Date().timeIntervalSince(clock)
        return result
    }
}
