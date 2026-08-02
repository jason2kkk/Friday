// 功能：定义 Talk 单值音量和多段声波强度的轻量跨层数据契约。
// 职责：为 ConversationAudioService 的音频输出和 Conversation Presentation 的视觉输入提供稳定、与框架无关的共同模型。
// 边界：只承载已归一化数值，不计算音量、不持有音频缓冲，也不包含任何 UI 样式。

import Foundation

struct ConversationAudioLevels {
    let level: Float
    let waveformLevels: [Float]
}
