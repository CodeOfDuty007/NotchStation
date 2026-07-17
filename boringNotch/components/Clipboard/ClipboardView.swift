//
//  ClipboardView.swift
//  boringNotch
//

import SwiftUI

struct ClipboardView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var cvm = ClipboardStateViewModel.shared

    private let spacing: CGFloat = 8

    var body: some View {
        historyPanel
    }

    private var historyPanel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
    }

    private var content: some View {
        Group {
            if cvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)

                    Text("Everything you copy lands here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(cvm.items) { item in
                            ClipboardItemView(item: item)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

struct ClipboardItemView: View {
    let item: ClipboardItem

    @ObservedObject private var cvm = ClipboardStateViewModel.shared
    @State private var hovering = false
    @State private var justCopied = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(hovering ? 0.14 : 0.07))
            .overlay {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    HStack(spacing: 4) {
                        Text(item.date, style: .time)
                        Spacer(minLength: 0)
                        Text("\(item.text.count) chars")
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button {
                        cvm.remove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            .overlay {
                if justCopied {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.55))
                        .overlay {
                            Label("Copied", systemImage: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                }
            }
            .frame(width: 120)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
            .onTapGesture {
                cvm.copyToPasteboard(item)
                withAnimation(.smooth) { justCopied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation(.smooth) { justCopied = false }
                }
            }
            .help("Click to copy")
    }
}
