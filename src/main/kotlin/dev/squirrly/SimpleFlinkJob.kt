package dev.squirrly

import org.apache.flink.api.common.eventtime.WatermarkStrategy
import org.apache.flink.api.common.functions.MapFunction
import org.apache.flink.api.common.typeinfo.Types
import org.apache.flink.connector.datagen.source.DataGeneratorSource
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment
import org.apache.flink.streaming.api.functions.sink.v2.DiscardingSink
import java.util.Random

/**
 * Dead-simple Flink job that will continually generate integer values, transform them
 * and eventually send them into the void. This job is just serving as a placeholder
 * for future complexity/analysis.
 */
object SimpleFlinkJob {
    @JvmStatic
    fun main(args: Array<String>) {
        val streamEnv = getDefaultExecutionEnvironment()

        streamEnv
            .fromSource(
                DataGeneratorSource(
                    { Random().nextInt(100) + 1 },
                    Long.MAX_VALUE, // Unbounded stream
                    Types.INT
                ),
                WatermarkStrategy.noWatermarks(),
                "continual-random-number-source"
            )
            .map(IntentionallyInefficientMapFunction())
            .name("inefficient-multiply-and-add")
            .map(EvenStallingFunction())
            .name("arbitrary-stall-on-even-values")
            .map(NotVeryGoodMapFunction())
            .name("not-very-good-string-conversion")
            .sinkTo(DiscardingSink())
            .name("discarding-sink")

        streamEnv.executeAsync("Intentionally Inefficient Flink Job")
    }

    private fun getDefaultExecutionEnvironment(): StreamExecutionEnvironment {
        return StreamExecutionEnvironment.getExecutionEnvironment()
            .apply {
                enableCheckpointing(5000)
                disableOperatorChaining()
            }
    }



    // Intentionally inefficient pipeline functions

    private class IntentionallyInefficientMapFunction : MapFunction<Int, Int> {
        override fun map(value: Int): Int {
            fun double(x: Int) = listOf(x).first() * 2
            val doubled = run { double(value.toString().toInt()) }
            return doubled.plus(123)
        }
    }

    private class EvenStallingFunction : MapFunction<Int, Int> {
        override fun map(value: Int): Int {
            Thread.sleep(random.nextLong(0, 250))
            return value
        }

        companion object {
            val random = Random(42)
        }
    }

    private class NotVeryGoodMapFunction : MapFunction<Int, String> {
        override fun map(value: Int): String {
            val s = value.toString()
            return String(s.toCharArray())
        }
    }
}

