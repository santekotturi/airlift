#if DEBUG
import Foundation

/// Real Apple Watch tachograms lifted out of a Health export, with the
/// values the reference Python implementation computes from the same
/// beats (`recoverylab/analysis/validate_rr_hrv.py`).
///
/// Hand-worked examples prove the formula. These prove the formula survives
/// real beats — midnight rollovers, ectopics, readings the filter mostly
/// rejects — and that the app and the analysis agree to the last decimal on
/// data neither of them was written against.
///
/// Generated, not hand-edited. Beat offsets are seconds from the start of
/// the series, on the export's 10 ms grid.
enum TachogramFixtures {
    struct Case {
        let record: Int
        let offsets: [Double]
        /// Expected RMSSD in milliseconds.
        let rmssd: Double
        /// Expected SDNN in milliseconds.
        let sdnn: Double
        let meanRR: Double
        let acceptedIntervals: Int
        let successivePairs: Int
        /// What Apple published for this same reading.
        let publishedSDNN: Double
    }

    static let all: [Case] = [
        Case(
            record: 1252040,
            offsets: [0, 1.11, 2.18, 3.19, 4.21, 5.24, 6.31, 7.38, 8.4, 9.43, 10.46, 11.54, 12.61, 13.69, 14.85, 16.08, 17.15, 18.25, 19.34, 20.41, 21.4, 22.4, 23.46, 24.53, 25.55, 26.64, 27.8, 28.95, 30.02, 31.11, 32.24, 33.36, 34.38, 35.49, 36.63, 37.75, 38.78, 39.76, 40.8, 41.92, 43.18, 44.3, 45.49, 46.76, 47.92, 48.99, 50.14, 51.28, 52.32, 53.36, 54.45, 55.58, 56.69, 57.73],
            rmssd: 64.792568,
            sdnn: 63.725646,
            meanRR: 1089.245283,
            acceptedIntervals: 53,
            successivePairs: 52,
            publishedSDNN: 63.389900
        ),
        Case(
            record: 1248195,
            offsets: [0, 0.86, 1.66, 2.4, 3.13, 3.85, 4.58, 5.29, 6, 6.7, 7.42, 8.25, 9.12, 10.06, 10.97, 11.85, 12.7, 13.47, 14.24, 15, 15.76, 16.53, 17.31, 18.1, 18.86],
            rmssd: 40.324769,
            sdnn: 67.753817,
            meanRR: 785.833333,
            acceptedIntervals: 24,
            successivePairs: 23,
            publishedSDNN: 67.476000
        ),
        Case(
            record: 1253008,
            offsets: [0, 0.84, 1.69, 2.55, 3.43, 4.35, 5.22, 6.07, 6.91, 7.79, 8.65, 9.52, 10.34, 11.18, 12.04, 12.91, 13.79, 33.35, 34.12, 34.91, 35.69, 36.49, 37.3, 38.11, 38.9, 39.71, 40.54, 41.51, 42.68, 43.56, 44.42, 45.32, 48.29, 49.21, 53.37, 54.13, 54.85, 55.6, 56.42, 57.3, 58.21],
            rmssd: 38.729833,
            sdnn: 52.905276,
            meanRR: 843.055556,
            acceptedIntervals: 36,
            successivePairs: 31,
            publishedSDNN: 56.217400
        ),
        Case(
            record: 1244064,
            offsets: [0, 1, 2, 2.99, 4.08, 5.26, 6.44, 7.65, 8.85, 19.64, 20.62],
            rmssd: 52.372294,
            sdnn: 100.595449,
            meanRR: 1092.222222,
            acceptedIntervals: 9,
            successivePairs: 7,
            publishedSDNN: 102.390000
        ),
        Case(
            record: 1257170,
            offsets: [0, 2.31, 4.51, 5.24, 5.97, 6.7, 7.44, 8.18, 8.92, 9.7, 10.52, 11.28, 12.06, 12.85, 13.62, 14.37, 15.12, 15.85, 16.57, 17.29, 18.03, 18.89, 19.79, 20.64, 21.49, 22.31, 23.16, 24.02, 24.82, 25.63, 26.43, 27.2, 27.95, 28.68, 29.44, 30.19, 30.98, 33.31, 34.13, 34.93, 35.72, 36.51, 42.94, 43.66, 44.47, 45.28, 46.08, 46.91, 47.75, 48.54, 49.31, 50.1, 50.87, 51.61, 52.36, 53.12, 53.93, 54.77, 55.56, 56.31, 57.06, 57.84],
            rmssd: 110.000000,
            sdnn: 70.000000,
            meanRR: 2280.000000,
            acceptedIntervals: 3,
            successivePairs: 1,
            publishedSDNN: 44.758100
        ),
        Case(
            record: 1247114,
            offsets: [0, 2.19, 4.45, 5.27, 6.22, 7.16, 8.1, 9.18, 10.34, 11.39, 12.46, 13.68, 14.81, 15.84, 16.95, 18.21, 19.57, 20.77, 22.19, 23.75, 25.18, 26.65, 27.96, 29.17, 30.37, 31.57, 32.77, 34.24, 35.59, 37.04, 38.38, 39.64, 40.88, 42.16, 43.32, 44.56, 46.02, 47.41, 48.84, 50.13, 51.46, 52.66, 53.9, 55.1, 56.27, 57.49],
            rmssd: 70.000000,
            sdnn: 49.497475,
            meanRR: 2225.000000,
            acceptedIntervals: 2,
            successivePairs: 1,
            publishedSDNN: 151.357000
        ),
    ]
}
#endif
