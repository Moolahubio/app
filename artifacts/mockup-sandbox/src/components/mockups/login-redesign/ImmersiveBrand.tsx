import React, { useState } from "react";
import { Eye, EyeOff, Fingerprint } from "lucide-react";
import "./_group.css";
import "./_immersive.css";
import { Wordmark, AscendingChart, MH } from "./_Brand";

export function ImmersiveBrand() {
  const [showPassword, setShowPassword] = useState(false);

  return (
    <div className="relative min-h-screen w-full overflow-hidden text-white flex items-center" style={{ backgroundColor: MH.ink950 }}>
      {/* Immersive Background */}
      <div className="absolute inset-0 z-0 mh-grid-dark opacity-30" />
      
      {/* Ambient Glows */}
      <div className="absolute top-[-20%] left-[-10%] w-[1000px] h-[1000px] mh-glow-circle z-0 rounded-full pointer-events-none" />
      <div className="absolute bottom-[-30%] right-[-10%] w-[1200px] h-[1200px] mh-glow-circle z-0 rounded-full pointer-events-none opacity-50" />

      {/* Ascending Chart — Large & Cinematic */}
      <div className="absolute bottom-0 left-0 w-[140%] -ml-[20%] translate-y-[20%] z-0 opacity-40 pointer-events-none">
        <AscendingChart />
      </div>

      <div className="relative z-10 w-full h-full max-w-[1920px] mx-auto px-12 md:px-24 flex flex-col md:flex-row items-center justify-between gap-16 mh-animate-fade-up">
        
        {/* Left: Brand Aspiration */}
        <div className="flex-1 flex flex-col items-start pt-12 md:pt-0">
          <Wordmark tone="light" className="mb-16 scale-125 origin-left" />
          
          <div className="space-y-6 max-w-2xl">
            <div className="inline-flex items-center gap-3">
              <span className="mh-eyebrow" style={{ color: MH.jade400 }}>Saving, made social</span>
              <span className="w-1.5 h-1.5 rounded-full" style={{ backgroundColor: MH.jade400 }} />
              <span className="mh-eyebrow text-white/50">Built on Base</span>
            </div>
            
            <h1 className="mh-display text-6xl md:text-7xl lg:text-8xl font-semibold tracking-tight leading-[1.05]">
              Save today.<br />
              <span className="text-transparent bg-clip-text" style={{ backgroundImage: `linear-gradient(to right, ${MH.paper}, ${MH.jade300})` }}>
                Reach it together.
              </span>
            </h1>
            
            <p className="mh-sans text-xl md:text-2xl text-white/60 font-light max-w-xl leading-relaxed mt-4">
              Join trusted circles, build financial habits, and achieve your goals with the people you care about.
            </p>
          </div>
        </div>

        {/* Right: Glass Form Panel */}
        <div className="w-full max-w-[480px] shrink-0 mb-12 md:mb-0 mt-8 md:mt-0">
          <div className="mh-glass-card rounded-3xl p-10 md:p-12 backdrop-blur-2xl">
            <div className="mb-8">
              <h2 className="mh-display text-3xl font-semibold text-white mb-2">Welcome back</h2>
              <p className="mh-sans text-white/60">Sign in to keep saving toward your goals.</p>
            </div>

            <form className="space-y-6" onSubmit={(e) => e.preventDefault()}>
              <div className="space-y-2">
                <label className="mh-sans text-sm font-medium text-white/80 block">Email address</label>
                <input 
                  type="email" 
                  placeholder="you@example.com" 
                  className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-3.5 mh-sans text-white placeholder:text-white/30 focus:outline-none focus:border-[#0E9E6E] focus:ring-1 focus:ring-[#0E9E6E] transition-all"
                />
              </div>

              <div className="space-y-2">
                <label className="mh-sans text-sm font-medium text-white/80 block">Password</label>
                <div className="relative">
                  <input 
                    type={showPassword ? "text" : "password"} 
                    placeholder="Your password" 
                    className="w-full bg-white/5 border border-white/10 rounded-xl pl-4 pr-12 py-3.5 mh-sans text-white placeholder:text-white/30 focus:outline-none focus:border-[#0E9E6E] focus:ring-1 focus:ring-[#0E9E6E] transition-all"
                  />
                  <button 
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-4 top-1/2 -translate-y-1/2 text-white/40 hover:text-white/80 transition-colors"
                  >
                    {showPassword ? <EyeOff size={20} strokeWidth={1.5} /> : <Eye size={20} strokeWidth={1.5} />}
                  </button>
                </div>
              </div>

              <div className="flex items-center justify-between pt-2">
                <label className="flex items-center gap-3 cursor-pointer group">
                  <div className="relative flex items-center justify-center">
                    <input type="checkbox" className="peer sr-only" />
                    <div className="w-5 h-5 border border-white/20 rounded peer-checked:bg-[#0E9E6E] peer-checked:border-[#0E9E6E] transition-colors flex items-center justify-center">
                      <svg className="w-3 h-3 text-white opacity-0 peer-checked:opacity-100 transition-opacity" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                      </svg>
                    </div>
                  </div>
                  <span className="mh-sans text-sm text-white/70 group-hover:text-white/90 transition-colors">Keep me logged in for 30 days</span>
                </label>
                
                <a href="#" className="mh-sans text-sm font-medium transition-colors hover:text-white" style={{ color: MH.jade400 }}>
                  Forgot password?
                </a>
              </div>

              <button 
                className="w-full rounded-xl py-3.5 mh-sans font-semibold text-white shadow-lg hover:shadow-xl hover:opacity-90 transition-all mt-4 active:scale-[0.98]"
                style={{ backgroundColor: MH.jade500 }}
              >
                Sign in
              </button>

              <div className="flex items-center gap-4 py-4">
                <div className="h-px flex-1 bg-white/10" />
                <span className="mh-sans text-xs text-white/40 font-medium uppercase tracking-wider">Or</span>
                <div className="h-px flex-1 bg-white/10" />
              </div>

              <button 
                type="button"
                className="w-full flex items-center justify-center gap-2 rounded-xl py-3.5 border border-white/15 bg-white/5 hover:bg-white/10 mh-sans font-medium text-white transition-all active:scale-[0.98]"
              >
                <Fingerprint size={18} />
                <span>Sign in with passkey</span>
              </button>
            </form>

            <div className="mt-10 text-center">
              <p className="mh-sans text-white/50 text-sm">
                New to MoolaHub?{" "}
                <a href="#" className="font-medium transition-colors hover:text-white" style={{ color: MH.jade400 }}>
                  Create an account
                </a>
              </p>
            </div>
          </div>
        </div>

      </div>
    </div>
  );
}
