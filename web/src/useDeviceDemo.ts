import { useEffect, useState } from 'react';

export interface DeviceDemoState {
  temperature: number;
  humidity: number;
  fanOn: boolean;
  stage: 0 | 1 | 2 | 3;
  targetFanOn: boolean;
  automaticCommand: boolean;
  commandSequence: number;
  history: number[];
  toastMessage: string;
  toastSequence: number;
}

/** Tạo số liệu minh họa ban đầu cho biểu đồ, độc lập với API và thiết bị thật. */
function createInitialDemoState(): DeviceDemoState {
  return {
    temperature: 30.2,
    humidity: 61,
    fanOn: false,
    stage: 0,
    targetFanOn: false,
    automaticCommand: false,
    commandSequence: 0,
    // Tạo mẫu giả lập có dao động nhẹ để biểu đồ ban đầu trông tự nhiên.
    history: Array.from({ length: 40 }, (_, index) => 29.6 + Math.sin(index / 5) * 0.6 + Math.random() * 0.3),
    toastMessage: '',
    toastSequence: 0,
  };
}

/** Dựng đường và vùng nền biểu đồ từ 40 mẫu nhiệt độ hiển thị trong khung Web. */
export function buildSparkline(history: number[]): { line: string; area: string } {
  const width = 400;
  const height = 78;
  const points = history.map((temperature, index) => {
    const x = (index * width) / (history.length - 1);
    const boundedTemperature = Math.min(36, Math.max(26, temperature));
    const y = height - 6 - ((boundedTemperature - 26) / 10) * (height - 14);
    return `${index === 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`;
  });
  const line = points.join(' ');
  return { line, area: `${line} L${width} ${height} L0 ${height}Z` };
}

/** Giữ Web và màn hình điện thoại trong demo cùng một trạng thái lệnh và số đo. */
export function useDeviceDemo(): { state: DeviceDemoState; sendFanCommand: (fanOn: boolean) => void } {
  const [state, setState] = useState(createInitialDemoState);

  /** Bắt đầu lệnh demo; chặn thao tác lặp khi chưa nhận được kết quả giả lập. */
  function sendFanCommand(fanOn: boolean): void {
    // Chỉ nhận lệnh mới sau khi chuỗi lệnh đang chạy đã kết thúc.
    setState((current) => {
      if (current.stage === 1 || current.stage === 2) return current;
      return {
        ...current,
        stage: 1,
        targetFanOn: fanOn,
        automaticCommand: false,
        commandSequence: current.commandSequence + 1,
      };
    });
  }

  // Mỗi mã lệnh lên lịch một chuỗi tiếp nhận → xác nhận → ổn định; cleanup hủy chuỗi cũ.
  useEffect(() => {
    if (state.commandSequence === 0) return;
    const sequence = state.commandSequence;
    // Chuyển sang trạng thái đã nhận nếu đây vẫn là lệnh mới nhất.
    const acceptedTimer = window.setTimeout(() => {
      setState((current) => current.commandSequence === sequence ? { ...current, stage: 2 } : current);
    }, 750);
    // Chỉ cập nhật trạng thái quạt sau mốc xác nhận mô phỏng của cùng lệnh.
    const confirmedTimer = window.setTimeout(() => {
      setState((current) => current.commandSequence === sequence
        ? { ...current, fanOn: current.targetFanOn, stage: 3 }
        : current);
    }, 1500);
    // Thu trạng thái lệnh về rảnh nếu không có lệnh mới thay thế trong lúc chờ.
    const settledTimer = window.setTimeout(() => {
      setState((current) => current.commandSequence === sequence && current.stage === 3
        ? { ...current, stage: 0 }
        : current);
    }, 3000);
    // Hủy chuỗi xác nhận cũ khi có lệnh mới hoặc khi trang được tháo khỏi React tree.
    return () => {
      window.clearTimeout(acceptedTimer);
      window.clearTimeout(confirmedTimer);
      window.clearTimeout(settledTimer);
    };
  }, [state.commandSequence]);

  // Bộ hẹn giờ cập nhật dữ liệu giả lập và kích hoạt luật mẫu; chỉ tạo một lần khi gắn component.
  useEffect(() => {
    // Tính mẫu tiếp theo từ state mới nhất để timer không dùng closure dữ liệu cũ.
    const updateTimer = window.setInterval(() => {
      setState((current) => {
        const temperature = Math.min(35.5, Math.max(26,
          current.temperature + (current.fanOn ? -0.32 : 0.26) + (Math.random() - 0.5) * 0.3));
        const humidity = Math.min(72, Math.max(52,
          current.humidity + (Math.random() - 0.5) * 1.2 + (current.fanOn ? -0.15 : 0.1)));
        const next = {
          ...current,
          temperature,
          humidity,
          history: [...current.history.slice(1), temperature],
        };

        // Đây là dữ liệu mô phỏng cho landing page; không gửi lệnh đến backend hoặc thiết bị.
        if (current.stage === 0 && temperature >= 32 && !current.fanOn) {
          return {
            ...next,
            stage: 1 as const,
            targetFanOn: true,
            automaticCommand: true,
            commandSequence: current.commandSequence + 1,
            toastMessage: 'Luật “Làm mát phòng” vừa chạy: bật quạt',
            toastSequence: current.toastSequence + 1,
          };
        }
        if (current.stage === 0 && current.automaticCommand && current.fanOn && temperature <= 29) {
          return {
            ...next,
            stage: 1 as const,
            targetFanOn: false,
            automaticCommand: false,
            commandSequence: current.commandSequence + 1,
            toastMessage: 'Nhiệt độ đã ổn định: tắt quạt',
            toastSequence: current.toastSequence + 1,
          };
        }
        return next;
      });
    }, 1400);
    return () => window.clearInterval(updateTimer);
  }, []);

  // Ẩn thông báo tự động sau một khoảng ngắn, hủy timer nếu thông báo mới xuất hiện.
  useEffect(() => {
    if (state.toastSequence === 0) return;
    const sequence = state.toastSequence;
    // Chỉ ẩn thông báo nếu chưa có thông báo mới thay thế nó.
    const toastTimer = window.setTimeout(() => {
      setState((current) => current.toastSequence === sequence ? { ...current, toastMessage: '' } : current);
    }, 3200);
    return () => window.clearTimeout(toastTimer);
  }, [state.toastSequence]);

  return { state, sendFanCommand };
}
