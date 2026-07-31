import SwiftUI
import GestureEngine

/// 事件 tab：二级 tab + 编辑模式，动作类型 + step + 边界阈值
struct EventTabView: View {
    @Binding var config: AppConfig
    @State private var selectedEventID: UUID?
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var pendingDeleteEvent: EventConfig?

    private var selectedEvent: EventConfig? {
        config.events.first { $0.id == selectedEventID } ?? config.events.first
    }

    var body: some View {
        VStack(spacing: 0) {
            EditableTabBar(
                items: config.events,
                selection: $selectedEventID,
                nameKeyPath: \.name,
                isEditing: $isEditing,
                onAdd: addEvent,
                onDelete: { event in
                    if config.events.count <= 1 { return }
                    let boundCount = config.gestures.filter { $0.eventID == event.id }.count
                    if boundCount > 0 {
                        pendingDeleteEvent = event
                        showDeleteAlert = true
                    } else {
                        deleteEvent(event)
                    }
                },
                onRename: { event, newName in
                    if let idx = config.events.firstIndex(where: { $0.id == event.id }) {
                        config.events[idx].name = newName
                    }
                },
                canDelete: config.events.count > 1
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let event = selectedEvent, let idx = config.events.firstIndex(where: { $0.id == event.id }) {
                        Card(title: L10n.tr("动作类型", "Action Type")) {
                            Picker(L10n.tr("动作", "Action"), selection: Binding(
                                get: { config.events[idx].actionType },
                                set: { config.events[idx].actionType = $0 }
                            )) {
                                ForEach(ActionType.allCases, id: \.self) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Card(title: L10n.tr("调节参数", "Adjustment")) {
                            HStack {
                                Text(L10n.tr("每次变化量", "Step"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.events[idx].step) },
                                    set: { config.events[idx].step = Float($0) }
                                ), in: 0.005...0.05)
                                Text(String(format: "%.1f%%", config.events[idx].step * 100))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }

                        Card(title: L10n.tr("边界检测", "Boundary Detection")) {
                            HStack {
                                Text(L10n.tr("边界判定阈值", "Boundary Threshold"))
                                    .frame(width: 150, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(config.events[idx].boundaryThreshold) },
                                    set: { config.events[idx].boundaryThreshold = Float($0) }
                                ), in: 0.001...0.05)
                                Text(String(format: "%.3f", config.events[idx].boundaryThreshold))
                                    .monospacedDigit().frame(width: 50, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .alert(L10n.tr("确认删除事件？", "Delete event?"),
               isPresented: $showDeleteAlert) {
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
            Button(L10n.tr("删除", "Delete"), role: .destructive) {
                if let event = pendingDeleteEvent { deleteEvent(event) }
            }
        } message: {
            if let event = pendingDeleteEvent {
                let count = config.gestures.filter { $0.eventID == event.id }.count
                Text(L10n.tr("\(count) 个手势将解绑并重新绑定到第一个事件。此操作不可撤销。",
                            "\(count) gesture(s) will be rebound to the first event. This cannot be undone."))
            }
        }
    }

    private func addEvent() {
        let newEvent = EventConfig(name: "新事件", actionType: .volume, step: 0.0125, boundaryThreshold: 0.001)
        config.events.append(newEvent)
        selectedEventID = newEvent.id
    }

    private func deleteEvent(_ event: EventConfig) {
        guard let firstRemaining = config.events.first(where: { $0.id != event.id }) else { return }
        for i in 0..<config.gestures.count {
            if config.gestures[i].eventID == event.id {
                config.gestures[i].eventID = firstRemaining.id
            }
        }
        config.events.removeAll { $0.id == event.id }
        if selectedEventID == event.id {
            selectedEventID = firstRemaining.id
        }
    }
}
