package com.nemesis.coldstart;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;
import java.io.BufferedReader;
import java.io.InputStreamReader;

/**
 * Cold-start Heat settings. Writes one-value config files (read by the
 * coldstart.heat NEMESIS service) through the privileged `nemesis root`
 * channel, so this ordinary-uid app can persist to /data/nemesis/state.
 */
public class MainActivity extends Activity {

    static final String STATE = "/data/nemesis/state/coldstart.heat";
    static final String NEM = "/system/xbin/nemesis";
    static final String[] SEAT = { "Off", "Low", "Med", "High" };

    boolean enabled = true;
    int thresholdF = 50;      // trigger when outside temp is below this
    boolean wheel = true;
    int seatDrv = 0;          // 0..3
    int seatPass = 0;         // 0..3
    boolean uiTempIsC = false; // dashboard shows Celsius (affects fallback temp source)

    TextView thrLabel, statusLabel;
    Button enBtn, wheelBtn, drvBtn, passBtn, unitBtn;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        loadConfig();

        ScrollView sv = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        root.setPadding(pad, pad, pad, pad);
        root.setBackgroundColor(Color.rgb(18, 20, 24));
        sv.addView(root);

        root.addView(title("Cold-start Heat"));
        root.addView(hint("When you start the car and it's colder than the "
                + "threshold, the selected heaters turn on automatically."));

        enBtn = new Button(this);
        enBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { enabled = !enabled; refresh(); }
        });
        root.addView(enBtn);

        root.addView(gap());
        thrLabel = new TextView(this);
        thrLabel.setTextColor(Color.WHITE);
        thrLabel.setTextSize(18);
        root.addView(thrLabel);

        final SeekBar sb = new SeekBar(this);
        sb.setMax(80);                 // 0..80 F
        sb.setProgress(thresholdF);
        sb.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onProgressChanged(SeekBar s, int p, boolean u) { thresholdF = p; updateThr(); }
            public void onStartTrackingTouch(SeekBar s) {}
            public void onStopTrackingTouch(SeekBar s) {}
        });
        root.addView(sb);

        unitBtn = new Button(this);
        unitBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { uiTempIsC = !uiTempIsC; refresh(); }
        });
        root.addView(unitBtn);
        root.addView(hint("Set this to match the unit your dashboard shows. If your "
                + "car reports outside temp in Celsius, leaving this on °F makes the "
                + "heaters fire every start."));

        root.addView(gap());
        root.addView(section("Heaters to turn on"));

        wheelBtn = new Button(this);
        wheelBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { wheel = !wheel; refresh(); }
        });
        root.addView(wheelBtn);

        drvBtn = new Button(this);
        drvBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { seatDrv = (seatDrv + 1) % 4; refresh(); }
        });
        root.addView(drvBtn);

        passBtn = new Button(this);
        passBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { seatPass = (seatPass + 1) % 4; refresh(); }
        });
        root.addView(passBtn);

        root.addView(gap());
        Button save = new Button(this);
        save.setText("Save");
        save.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { saveConfig(); }
        });
        root.addView(save);

        Button test = new Button(this);
        test.setText("Test now (apply, ignore temp)");
        test.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { testNow(); }
        });
        root.addView(test);

        Button off = new Button(this);
        off.setText("All heaters OFF now");
        off.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { allOff(); }
        });
        root.addView(off);

        statusLabel = new TextView(this);
        statusLabel.setTextColor(Color.rgb(140, 160, 180));
        statusLabel.setPadding(0, dp(16), 0, 0);
        root.addView(statusLabel);

        setContentView(sv);
        refresh();
    }

    void updateThr() {
        int c = Math.round((thresholdF - 32) * 5f / 9f);
        thrLabel.setText("Trigger below:  " + thresholdF + " °F  (" + c + " °C)");
    }

    void refresh() {
        enBtn.setText(enabled ? "Automation: ON" : "Automation: OFF");
        wheelBtn.setText("Steering wheel:  " + (wheel ? "ON" : "off"));
        drvBtn.setText("Driver seat:  " + SEAT[seatDrv]);
        passBtn.setText("Passenger seat:  " + SEAT[seatPass]);
        unitBtn.setText("My dashboard shows:  " + (uiTempIsC ? "°C" : "°F"));
        updateThr();
    }

    // ---- config I/O via `nemesis root -c` -------------------------------
    String runRoot(String cmd) {
        StringBuilder out = new StringBuilder();
        try {
            Process p = Runtime.getRuntime().exec(new String[] { NEM, "root", "-c", cmd });
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = r.readLine()) != null) out.append(line).append("\n");
            p.waitFor();
        } catch (Exception e) {
            return "ERR " + e.getMessage();
        }
        return out.toString();
    }

    int readInt(String name, int def) {
        String v = runRoot("cat " + STATE + "/" + name + " 2>/dev/null").trim();
        try { return Integer.parseInt(v.trim()); } catch (Exception e) { return def; }
    }

    void loadConfig() {
        enabled   = readInt("enabled", 1) == 1;
        thresholdF= clamp(readInt("threshold_f", 50), 0, 80);
        wheel     = readInt("wheel", 1) == 1;
        seatDrv   = clamp(readInt("seat_drv", 0), 0, 3);
        seatPass  = clamp(readInt("seat_pass", 0), 0, 3);
        uiTempIsC = readInt("ui_temp_is_c", 0) == 1;
    }

    void saveConfig() {
        String cmd = "mkdir -p " + STATE
            + "; echo " + (enabled ? 1 : 0) + " > " + STATE + "/enabled"
            + "; echo " + thresholdF + " > " + STATE + "/threshold_f"
            + "; echo " + (wheel ? 1 : 0) + " > " + STATE + "/wheel"
            + "; echo " + seatDrv + " > " + STATE + "/seat_drv"
            + "; echo " + seatPass + " > " + STATE + "/seat_pass"
            + "; echo " + (uiTempIsC ? 1 : 0) + " > " + STATE + "/ui_temp_is_c";
        String r = runRoot(cmd);
        if (r.startsWith("ERR")) toast("Save failed: " + r);
        else { toast("Saved"); statusLabel.setText("Saved: below " + thresholdF
            + "°F → wheel " + (wheel ? "on" : "off")
            + ", drv " + SEAT[seatDrv] + ", pass " + SEAT[seatPass]
            + "  [dash " + (uiTempIsC ? "°C" : "°F") + "]"); }
    }

    // UI level 1/2/3 (Low/Med/High) -> seat enum 6/7/8 ; else 2 (off)
    int seatEnum(int lvl) {
        switch (lvl) { case 1: return 6; case 2: return 7; case 3: return 8; default: return 2; }
    }

    void testNow() {
        StringBuilder c = new StringBuilder();
        if (wheel)        c.append("service call com.hkmc.vr 16 i32 1; ");
        if (seatDrv > 0)  c.append("service call com.hkmc.micom.usm 213 i32 ").append(seatEnum(seatDrv)).append("; ");
        if (seatPass > 0) c.append("service call com.hkmc.micom.usm 214 i32 ").append(seatEnum(seatPass)).append("; ");
        if (c.length() == 0) { toast("Nothing selected"); return; }
        runRoot(c.toString());
        statusLabel.setText("Applied now: wheel " + (wheel ? "on" : "off")
            + ", drv " + SEAT[seatDrv] + ", pass " + SEAT[seatPass]);
        toast("Applied");
    }

    void allOff() {
        runRoot("service call com.hkmc.vr 16 i32 0; service call com.hkmc.micom.usm 213 i32 2; "
              + "service call com.hkmc.micom.usm 214 i32 2");
        statusLabel.setText("All heaters commanded off.");
        toast("Off");
    }

    // ---- small view helpers --------------------------------------------
    int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density); }
    int clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
    void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }

    TextView title(String s) {
        TextView t = new TextView(this);
        t.setText(s); t.setTextColor(Color.WHITE); t.setTextSize(26);
        t.setPadding(0, 0, 0, dp(8)); return t;
    }
    TextView section(String s) {
        TextView t = new TextView(this);
        t.setText(s); t.setTextColor(Color.rgb(120, 180, 255)); t.setTextSize(16);
        t.setPadding(0, dp(8), 0, dp(4)); return t;
    }
    TextView hint(String s) {
        TextView t = new TextView(this);
        t.setText(s); t.setTextColor(Color.rgb(150, 160, 170)); t.setTextSize(13);
        t.setPadding(0, 0, 0, dp(12)); return t;
    }
    View gap() { View v = new View(this); v.setMinimumHeight(dp(10)); return v; }
}
