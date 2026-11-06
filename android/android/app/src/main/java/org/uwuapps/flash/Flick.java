/*
 * Flick to change cards, while presenting with it switched on (FlashPlugin.flick): a sharp turn
 * of the wrist to the right is the next card, to the left the one before, so the phone can be
 * held up to a room and worked without touching the screen.
 *
 * What counts is how fast the phone turns about the vertical, whichever way it's held: the
 * gyroscope's rate of turn, projected onto gravity (from the accelerometer, smoothed). Upright,
 * sideways, screen to you or screen to the room, a turn to the right is the same turn. Holding a
 * sign up, walking with it, or tilting it towards someone turns it far slower than a flick does.
 * After a flick, the wrist coming back the other way is ignored.
 *
 * Runs only while the presenter has it on: the sensors are off the rest of the time.
 */
package org.uwuapps.flash;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.SystemClock;

final class Flick implements SensorEventListener {
    interface Listener {
        /** 1 for the next card, -1 for the one before. On the main thread. */
        void flick(int direction);
    }

    // Radians a second about the vertical. A flick of the wrist peaks at 6 to 10; handling a
    // phone, turning to someone or walking stays under 3.
    private static final float THRESHOLD = 5f;
    // After a flick, long enough for the wrist to come back, which is a turn the other way.
    private static final long QUIET_MS = 700;
    // How much of each accelerometer reading goes into the smoothed gravity.
    private static final float SMOOTHING = 0.1f;

    private final SensorManager sensors;
    private final Sensor gyroscope;
    private final Sensor accelerometer;
    private final float[] gravity = {0f, 0f, SensorManager.GRAVITY_EARTH};
    private Listener listener;
    private long quietUntil;

    private Flick(SensorManager sensors) {
        this.sensors = sensors;
        gyroscope = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
        accelerometer = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
    }

    /** Null on a phone without a gyroscope, which many cheaper ones lack. */
    static Flick create(Context context) {
        SensorManager sensors = (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
        if (sensors == null || sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE) == null
                || sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) == null) return null;
        return new Flick(sensors);
    }

    void start(Listener l) {
        if (listener != null) {
            listener = l;
            return;
        }
        listener = l;
        quietUntil = 0;
        sensors.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME);
        sensors.registerListener(this, gyroscope, SensorManager.SENSOR_DELAY_GAME);
    }

    void stop() {
        if (listener == null) return;
        listener = null;
        sensors.unregisterListener(this);
    }

    @Override
    public void onSensorChanged(SensorEvent event) {
        float[] v = event.values;
        if (event.sensor.getType() == Sensor.TYPE_ACCELEROMETER) {
            for (int i = 0; i < 3; i++) gravity[i] += SMOOTHING * (v[i] - gravity[i]);
            return;
        }
        Listener l = listener;
        if (l == null) return;
        float g = (float) Math.sqrt(gravity[0] * gravity[0] + gravity[1] * gravity[1] + gravity[2] * gravity[2]);
        if (g < 1f) return; // Falling, or not settled yet.
        // Turn about "up": positive is anticlockwise seen from above, a turn to the left.
        float turn = (v[0] * gravity[0] + v[1] * gravity[1] + v[2] * gravity[2]) / g;
        long now = SystemClock.elapsedRealtime();
        if (Math.abs(turn) < THRESHOLD || now < quietUntil) return;
        quietUntil = now + QUIET_MS;
        l.flick(turn < 0 ? 1 : -1);
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
    }
}
