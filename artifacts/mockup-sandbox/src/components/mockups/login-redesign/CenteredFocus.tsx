import React, { useState } from "react";
import { Eye, EyeOff, Fingerprint } from "lucide-react";
import "./_group.css";
import "./_centered.css";
import { Wordmark, AscendingChart, MH } from "./_Brand";

export function CenteredFocus() {
  const [showPassword, setShowPassword] = useState(false);

  return (
    <div className="min-h-screen w-full mh-centered-bg flex flex-col items-center justify-center relative overflow-hidden mh-grid-dark font-['Inter',sans-serif]">
      {/* Background Atmosphere */}
      <div className="mh-centered-glow" />
      <div className="mh-centered-chart">
        <AscendingChart />
      </div>

      <div className="relative z-10 w-full max-w-md px-6 mh-animate-fade-up">
        {/* Minimal Chrome */}
        <div className="flex flex-col items-center mb-8">
          <Wordmark tone="light" className="mb-4" />
          <span className="mh-eyebrow text-[#0E9E6E] bg-[#0E9E6E]/10 px-3 py-1 rounded-full">
            Built on Base
          </span>
        </div>

        {/* The Card */}
        <div className="mh-centered-card rounded-2xl p-10 w-full">
          <div className="text-center mb-8">
            <h1 className="mh-display text-3xl font-bold text-white mb-2 tracking-tight">Welcome back</h1>
            <p className="text-[#5C7468] text-sm">Sign in to keep saving toward your goals.</p>
          </div>

          <form className="space-y-5" onSubmit={(e) => e.preventDefault()}>
            <div className="space-y-1.5">
              <label className="block text-sm font-medium text-[#A1EAC9]">Email address</label>
              <div className="mh-input rounded-xl flex items-center px-4 py-3 h-12">
                <input 
                  type="email" 
                  placeholder="you@example.com" 
                  className="bg-transparent border-none outline-none w-full text-white placeholder:text-[#3A5046]"
                />
              </div>
            </div>

            <div className="space-y-1.5">
              <label className="block text-sm font-medium text-[#A1EAC9]">Password</label>
              <div className="mh-input rounded-xl flex items-center px-4 py-3 h-12">
                <input 
                  type={showPassword ? "text" : "password"} 
                  placeholder="Your password" 
                  className="bg-transparent border-none outline-none w-full text-white placeholder:text-[#3A5046]"
                />
                <button 
                  type="button" 
                  onClick={() => setShowPassword(!showPassword)}
                  className="text-[#5C7468] hover:text-[#A1EAC9] transition-colors focus:outline-none"
                >
                  {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between pt-2">
              <label className="flex items-center gap-2 cursor-pointer group">
                <div className="relative flex items-center justify-center w-4 h-4 rounded border border-[#1B2A24] bg-[#070D0B] group-hover:border-[#0E9E6E] transition-colors">
                  <input type="checkbox" className="peer sr-only" />
                  <div className="absolute w-2 h-2 rounded-sm bg-[#0E9E6E] opacity-0 peer-checked:opacity-100 transition-opacity" />
                </div>
                <span className="text-sm text-[#5C7468] group-hover:text-[#A1EAC9] transition-colors">Keep me logged in</span>
              </label>
              <a href="#" className="text-sm text-[#0E9E6E] hover:text-[#30C58A] font-medium transition-colors">
                Forgot password?
              </a>
            </div>

            <button className="w-full bg-[#0E9E6E] hover:bg-[#30C58A] text-white mh-display font-semibold rounded-xl h-12 mt-4 transition-colors shadow-[0_0_20px_rgba(14,158,110,0.3)]">
              Sign in
            </button>

            <div className="relative py-4">
              <div className="absolute inset-0 flex items-center">
                <div className="w-full border-t border-[#1B2A24]"></div>
              </div>
              <div className="relative flex justify-center text-xs">
                <span className="bg-[#0C1512] px-2 text-[#3A5046]">or</span>
              </div>
            </div>

            <button className="w-full bg-transparent border border-[#1B2A24] hover:border-[#3A5046] hover:bg-[#14201B] text-white mh-sans font-medium rounded-xl h-12 transition-all flex items-center justify-center gap-2">
              <Fingerprint size={18} className="text-[#67DBAB]" />
              Sign in with passkey
            </button>
          </form>
        </div>

        <div className="mt-8 text-center">
          <p className="text-[#5C7468] text-sm">
            New to MoolaHub? <a href="#" className="text-[#0E9E6E] hover:text-[#30C58A] font-medium ml-1">Create an account</a>
          </p>
        </div>
      </div>
    </div>
  );
}
