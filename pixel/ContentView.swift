//
//  ContentView.swift
//  pixel
//
//  Created by adam on 01.01.2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vm = FacePixelateCameraViewModel()

    @State private var pixelScaleDraft: Double = 40
    @State private var facePaddingDraft: Double = 0.22

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if let cg = vm.currentFrame {
                    Image(decorative: cg, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                        .background(Color.black.opacity(0.85))
                } else {
                    Text(vm.statusText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 680, minHeight: 520)

            Divider()

            Form {
                GroupBox("Фильтр") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Размер пикселя") {
                            HStack(spacing: 10) {
                                Text("\(Int(pixelScaleDraft))")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)

                                Slider(
                                    value: $pixelScaleDraft,
                                    in: 20...200,
                                    step: 10,
                                    onEditingChanged: { editing in
                                        if !editing { vm.commitPixelScale(pixelScaleDraft) }
                                    }
                                )
                            }
                        }

                        LabeledContent("Зона вокруг лица") {
                            HStack(spacing: 10) {
                                Text("+\(Int(facePaddingDraft * 100))%")
                                    .monospacedDigit()
                                    .frame(width: 64, alignment: .trailing)

                                Slider(
                                    value: $facePaddingDraft,
                                    in: 0.0...0.9,
                                    step: 0.01,
                                    onEditingChanged: { editing in
                                        if !editing { vm.commitFacePadding(facePaddingDraft) }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Статус") {
                    Text(vm.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(width: 340)
            .padding(10)
        }
        .onAppear {
            vm.start()
            pixelScaleDraft = max(20, (vm.uiPixelScale / 10).rounded() * 10)
            facePaddingDraft = vm.uiFacePadding
            vm.commitPixelScale(pixelScaleDraft)
            vm.commitFacePadding(facePaddingDraft)
        }
        .onDisappear { vm.stop() }
    }
}
