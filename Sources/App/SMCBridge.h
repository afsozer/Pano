#ifndef SMCBridge_h
#define SMCBridge_h

/// Average CPU / GPU die temperature in °C read from the SMC on Apple Silicon.
/// Returns NaN when no sensor is available (e.g. on Intel Macs).
double SMCReadAverageCPUTemperature(void);
double SMCReadAverageGPUTemperature(void);

#endif
